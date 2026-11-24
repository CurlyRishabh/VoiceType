import Foundation
import VoiceTypeCore

/// Owns the loaded speech model. Load, decode and release all run on ONE serial queue, so an idle
/// or memory-pressure release can never free a model in the middle of a decode.
final class SpeechHost {
    struct Transcript {
        let text: String
        let audioMillis: Int
        let decodeMillis: Int
        let loadMillis: Int
        let spec: EngineSpec
        var rtf: Double { audioMillis == 0 ? 0 : Double(decodeMillis) / Double(audioMillis) }
    }

    private let queue = DispatchQueue(label: "speech-engine", qos: .userInitiated)
    private let modelsRoot: URL
    private let idleRelease: TimeInterval = 5 * 60
    private var engine: SpeechRecognizing?
    private var idleItem: DispatchWorkItem?
    private var memoryPressure: DispatchSourceMemoryPressure?

    private(set) var lastLoadMillis = 0
    private(set) var loadedSpec: EngineSpec?
    /// For the Debug tab: the loaded engine, and the language of the last decode (whisper.cpp takes
    /// the language per call, so the load-time language says little).
    private(set) var loadedName: String?
    private(set) var lastLanguage: String?
    var isRecording: () -> Bool = { false }
    /// A meeting is recording: keep the model (no idle release, no release on a memory *warning*).
    private var held = false

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Critical pressure still wins; a meeting's next chunk then simply loads the model again.
            if source.data.contains(.critical) || !(self.isRecording() || self.held) {
                NSLog("VoiceType: memory pressure, releasing speech model")
                self.releaseNow()
            }
        }
        source.resume()
        memoryPressure = source
    }

    func warmUp(_ spec: EngineSpec) {
        queue.async { do { _ = try self.ensureLoaded(spec) } catch { NSLog("VoiceType warm-up: \(error.localizedDescription)") } }
    }

    /// `audioMillis` is the real recording length (chunks may be silence-padded for Whisper).
    /// `prompt`: vocabulary hint for whisper.cpp (ignored by the sherpa-onnx engines).
    func transcribe(_ spec: EngineSpec, chunks: [[Float]], audioMillis: Int, prompt: String? = nil,
                    completion: @escaping (Result<Transcript, Error>) -> Void) {
        queue.async {
            if chunks.isEmpty { // barrier: runs after every job queued before it
                completion(.success(Transcript(text: "", audioMillis: 0, decodeMillis: 0, loadMillis: 0, spec: spec)))
                return
            }
            do {
                let load = try self.ensureLoaded(spec)
                let start = DispatchTime.now()
                let engine = self.engine!
                self.lastLanguage = spec.language
                let text = chunks.map { engine.transcribe($0, prompt: prompt, language: spec.language) }.joined(separator: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let decode = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                let audio = audioMillis
                let t = Transcript(text: text, audioMillis: audio, decodeMillis: decode, loadMillis: load, spec: spec)
                NSLog("VoiceType: decoded %dms audio in %dms (RTF %.3f), load %dms, %@", audio, decode, t.rtf, load, engine.name)
                PerfLog.shared.add(.init(date: Date(), engine: engine.name + (spec.language.isEmpty ? "/auto" : "/" + spec.language),
                                         audioMillis: audio, decodeMillis: decode, loadMillis: load))
                self.scheduleIdleRelease()
                completion(.success(t))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// One meeting chunk -> timed segments. Meetings send ONE chunk per call, so a dictation queued
    /// meanwhile waits for at most one chunk instead of a whole backlog.
    struct TimedChunk {
        let segments: [TimedText]
        let language: String
        let decodeMillis: Int
        let loadMillis: Int
        let engine: String
    }

    func transcribeTimed(_ spec: EngineSpec, samples: [Float], prompt: String?,
                         completion: @escaping (Result<TimedChunk, Error>) -> Void) {
        queue.async {
            do {
                let load = try self.ensureLoaded(spec)
                let start = DispatchTime.now()
                let engine = self.engine!
                let r = try engine.transcribeTimed(samples, prompt: prompt, language: spec.language)
                self.lastLanguage = r.language
                let decode = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                self.scheduleIdleRelease()
                completion(.success(TimedChunk(segments: r.segments, language: r.language, decodeMillis: decode, loadMillis: load, engine: engine.name)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func release() { queue.async { self.releaseNow() } }

    /// Frees the model before the process exits (whisper.cpp's Metal backend aborts if one is still loaded).
    func releaseAndWait() { queue.sync { self.releaseNow() } }

    /// Keep the model loaded while a meeting records (see `held`).
    func hold(_ on: Bool) { queue.async { self.held = on; if !on { self.scheduleIdleRelease() } } }

    /// The loaded model can serve `spec` without a reload: same engine and threads, and the same
    /// language unless the engine takes the language per call.
    private func serves(_ spec: EngineSpec) -> Bool {
        guard let engine, let loaded = loadedSpec else { return false }
        return loaded.kind == spec.kind && loaded.threads == spec.threads && (engine.languagePerCall || loaded.language == spec.language)
    }

    private func ensureLoaded(_ spec: EngineSpec) throws -> Int {
        idleItem?.cancel()
        if serves(spec) { scheduleIdleRelease(); return 0 }
        releaseNow()
        let start = DispatchTime.now()
        let loaded = try Recognizers.make(spec, modelsRoot: modelsRoot)
        engine = loaded
        loadedSpec = spec
        loadedName = loaded.name
        lastLoadMillis = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        NSLog("VoiceType: loaded %@ in %dms", loaded.name, lastLoadMillis)
        scheduleIdleRelease()
        return lastLoadMillis
    }

    private func scheduleIdleRelease() {
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.held { self.scheduleIdleRelease() } else { self.releaseNow() }
        }
        idleItem = item
        queue.asyncAfter(deadline: .now() + idleRelease, execute: item)
    }

    private func releaseNow() {
        idleItem?.cancel()
        idleItem = nil
        if engine != nil { NSLog("VoiceType: released speech model") }
        engine = nil
        loadedSpec = nil
        loadedName = nil
    }
}

/// Recent timings for the Debug tab (memory only).
final class PerfLog {
    static let shared = PerfLog()
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let engine: String
        let audioMillis: Int
        let decodeMillis: Int
        let loadMillis: Int
        var polishMillis = -1
        var polishNote: String?
        var rtf: Double { audioMillis == 0 ? 0 : Double(decodeMillis) / Double(audioMillis) }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func add(_ e: Entry) { lock.lock(); entries.insert(e, at: 0); entries = Array(entries.prefix(30)); lock.unlock() }
    func annotateLatest(polishMillis: Int, note: String?) {
        lock.lock(); if !entries.isEmpty { entries[0].polishMillis = polishMillis; entries[0].polishNote = note }; lock.unlock()
    }
    var recent: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
}

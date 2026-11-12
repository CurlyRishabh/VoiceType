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
    private var engine: SherpaRecognizer?
    private var idleItem: DispatchWorkItem?
    private var memoryPressure: DispatchSourceMemoryPressure?

    private(set) var lastLoadMillis = 0
    private(set) var loadedSpec: EngineSpec?
    var isRecording: () -> Bool = { false }

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.critical) || !self.isRecording() {
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
    func transcribe(_ spec: EngineSpec, chunks: [[Float]], audioMillis: Int, completion: @escaping (Result<Transcript, Error>) -> Void) {
        queue.async {
            do {
                let load = try self.ensureLoaded(spec)
                let start = DispatchTime.now()
                let text = chunks.map { self.engine!.transcribe($0) }.joined(separator: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let decode = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                let audio = audioMillis
                let t = Transcript(text: text, audioMillis: audio, decodeMillis: decode, loadMillis: load, spec: spec)
                NSLog("VoiceType: decoded %dms audio in %dms (RTF %.3f), load %dms, %@", audio, decode, t.rtf, load, spec.kind.rawValue)
                PerfLog.shared.add(.init(date: Date(), engine: spec.kind.rawValue + (spec.language.isEmpty ? "/auto" : "/" + spec.language),
                                         audioMillis: audio, decodeMillis: decode, loadMillis: load))
                self.scheduleIdleRelease()
                completion(.success(t))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func release() { queue.async { self.releaseNow() } }

    private func ensureLoaded(_ spec: EngineSpec) throws -> Int {
        idleItem?.cancel()
        if engine != nil, loadedSpec == spec { scheduleIdleRelease(); return 0 }
        releaseNow()
        let start = DispatchTime.now()
        engine = try SherpaRecognizer(spec: spec, modelsRoot: modelsRoot)
        loadedSpec = spec
        lastLoadMillis = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        NSLog("VoiceType: loaded %@ in %dms", spec.kind.rawValue, lastLoadMillis)
        scheduleIdleRelease()
        return lastLoadMillis
    }

    private func scheduleIdleRelease() {
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.releaseNow() }
        idleItem = item
        queue.asyncAfter(deadline: .now() + idleRelease, execute: item)
    }

    private func releaseNow() {
        idleItem?.cancel()
        idleItem = nil
        if engine != nil { NSLog("VoiceType: released speech model") }
        engine = nil
        loadedSpec = nil
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

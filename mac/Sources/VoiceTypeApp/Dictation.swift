import AppKit
import AVFoundation
import Foundation
import VoiceTypeCore

/// One dictation: record -> speech-to-text -> clean-up -> result. Main-thread API.
///
/// Recording starts provisionally on the first trigger key-down (so no word is clipped); the gesture
/// later says finish or cancel. In hands-free mode, finished sentences are transcribed in the
/// background while you keep talking, so a long dictation is ready almost as soon as you stop.
final class Dictation {
    enum State { case idle, listening, transcribing, polishing }

    struct Target {
        let appName: String?
        let bundleID: String?
        let category: AppCategory
        let style: StyleChoice
        let startsSentence: Bool
        let endsSentence: Bool
    }

    var onState: ((State) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onResult: ((CleanupResult, Target) -> Void)?
    var onMessage: ((String) -> Void)?
    /// The recording stopped by itself (time limit, mic error); the gesture must reset.
    var onEndedByItself: (() -> Void)?

    private(set) var state: State = .idle { didSet { onState?(state) } }
    private(set) var handsFree = false
    private(set) var startedAt: Date?

    private let models: ModelStore
    private let speech: SpeechHost
    private let pipeline: CleanupPipeline
    private let polisher: AppleIntelligencePolisher
    private let history: HistoryStore
    private var recorder: Recorder?
    private var target: Target?
    private var spec = AppSettings.engineSpec
    private var generation = 0

    // Background transcription of a long session.
    private var decodedUpTo = 0
    private var partials: [String?] = []

    static let holdLimitMillis = 5 * 60_000
    static let handsFreeLimitMillis = 15 * 60_000
    private static let partialMinSamples = sampleRate * 6

    init(models: ModelStore, speech: SpeechHost, polisher: AppleIntelligencePolisher, history: HistoryStore) {
        self.models = models
        self.speech = speech
        self.polisher = polisher
        self.pipeline = CleanupPipeline(polisher: polisher, timeout: .seconds(3))
        self.history = history
        speech.isRecording = { [weak self] in self?.recorder != nil }
    }

    var isRecording: Bool { recorder != nil }

    func warmUp() {
        speech.warmUp(AppSettings.engineSpec)
        if UserDefaults.standard.bool(forKey: Key.polish) { polisher.warmUp() }
    }

    /// Starts recording (provisionally). Returns false and reports why if it can't.
    @discardableResult
    func begin() -> Bool {
        guard state == .idle, recorder == nil else { return false }
        spec = AppSettings.engineSpec
        let slot: ModelSlot = spec.kind == .fastEnglish ? .moonshine : .whisper
        guard models.isReady(slot) else { onMessage?("Speech model not imported"); return false }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            onMessage?("Allow the microphone, then try again")
            return false
        default:
            onMessage?("Microphone is blocked for VoiceType")
            return false
        }

        let front = NSWorkspace.shared.frontmostApplication
        let category = AppStyleMap.category(bundleID: front?.bundleIdentifier)
        let ctx = Inserter.focusedContext()
        target = Target(appName: front?.localizedName, bundleID: front?.bundleIdentifier, category: category,
                        style: AppSettings.styleChoice(category),
                        startsSentence: TextJoin.startsSentence(ctx.before), endsSentence: TextJoin.endsSentence(ctx.after))

        let rec = Recorder(vadModel: models.vadFile)
        rec.autoStop = false // you decide when to stop: release fn, or tap it in hands-free
        rec.maxDurationMillis = Self.holdLimitMillis
        rec.onLevel = { [weak self] in self?.onLevel?($0) }
        let gen = generation + 1
        generation = gen
        rec.onAutoStop = { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.onEndedByItself?()
            self.finish()
        }
        rec.onSegment = { [weak self] seg in
            guard let self, self.generation == gen else { return }
            self.segmentFinished(seg)
        }
        do {
            try rec.start()
        } catch {
            onMessage?("Microphone error: \(error.localizedDescription)")
            return false
        }
        warmUp()
        recorder = rec
        handsFree = false
        decodedUpTo = 0
        partials = []
        startedAt = Date()
        state = .listening
        return true
    }

    func enterHandsFree() {
        guard let rec = recorder else { return }
        handsFree = true
        rec.maxDurationMillis = Self.handsFreeLimitMillis
    }

    /// Throws the recording away (single tap, fn+key shortcut, esc, ✕).
    func cancel() {
        generation += 1
        recorder?.cancel()
        recorder = nil
        handsFree = false
        partials = []
        state = .idle
    }

    /// Stops and types what was said.
    func finish() {
        guard state == .listening, let rec = recorder else { return }
        recorder = nil
        state = .transcribing
        let gen = generation
        let captured = rec.stop()
        let spec = self.spec
        let whisper = spec.kind == .hindiEnglish

        // Only the part not already transcribed in the background is left.
        let start = min(decodedUpTo, captured.samples.count)
        let rest = Array(captured.samples[start...])
        let restSegments = captured.segments.map { segs in
            segs.compactMap { s -> Segment? in
                guard s.end > start else { return nil }
                let a = max(s.start, start)
                return Segment(start: a - start, length: s.end - a)
            }
        }
        let hasPartials = !partials.isEmpty
        if !captured.speechDetected && !hasPartials {
            done(gen) { self.onMessage?("Didn't catch that") }
            return
        }
        if UserDefaults.standard.bool(forKey: Key.keepRecordings) { saveRecording(captured.samples) }

        let chunks = (restSegments?.isEmpty ?? false) ? [] :
            DecodePlan.chunks(samples: rest, segments: restSegments, whisper: whisper, language: spec.language)
        let speechMs = captured.speechMillis
        let audioMs = captured.durationMillis
        let collect: (String) -> Void = { [weak self] tail in
            guard let self, gen == self.generation else { return }
            let raw = HallucinationFilter.clean((self.partials.compactMap { $0 } + [tail]).joined(separator: " "), speechMillis: speechMs)
            self.partials = []
            self.cleanUp(raw, audioMillis: audioMs, gen: gen)
        }
        if chunks.isEmpty {
            // Wait for in-flight background chunks: an empty job on the same serial queue runs after them.
            speech.transcribe(spec, chunks: [], audioMillis: 0) { _ in DispatchQueue.main.async { collect("") } }
            return
        }
        speech.transcribe(spec, chunks: chunks, audioMillis: rest.count * 1000 / sampleRate) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let t): collect(t.text)
                case .failure(let e): self?.done(gen) { self?.onMessage?(e.localizedDescription) }
                }
            }
        }
    }

    /// Hands-free: transcribe completed sentences while the user keeps talking.
    private func segmentFinished(_ seg: Segment) {
        guard handsFree, let rec = recorder, seg.end - decodedUpTo >= Self.partialMinSamples else { return }
        let end = seg.end + AudioChunker.pad
        let samples = rec.snapshot(decodedUpTo..<end)
        guard !samples.isEmpty else { return }
        decodedUpTo += samples.count
        let index = partials.count
        partials.append(nil)
        let gen = generation
        let chunks = DecodePlan.chunks(samples: samples, segments: nil, whisper: spec.kind == .hindiEnglish, language: spec.language)
        speech.transcribe(spec, chunks: chunks, audioMillis: samples.count * 1000 / sampleRate) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, index < self.partials.count else { return }
                if case .success(let t) = result { self.partials[index] = t.text } else { self.partials[index] = "" }
            }
        }
    }

    private func cleanUp(_ raw: String, audioMillis: Int, gen: Int) {
        guard gen == generation, let target else { return }
        if raw.isEmpty { done(gen) { self.onMessage?("Didn't catch that") }; return }
        let settings = AppSettings.cleanup(startsSentence: target.startsSentence, endsSentence: target.endsSentence,
                                           polishAvailable: polisher.isReady, style: target.style.polishStyle)
        if settings.polishEnabled { state = .polishing }
        let pipeline = self.pipeline
        let handsFree = self.handsFree
        let spec = self.spec
        Task {
            let result = await pipeline.process(raw, settings)
            await MainActor.run {
                PerfLog.shared.annotateLatest(polishMillis: settings.polishEnabled ? result.polishMillis : -1, note: result.fallbackReason)
                if UserDefaults.standard.bool(forKey: Key.history), !result.text.isEmpty {
                    self.history.add(.init(date: Date(), text: result.text, raw: raw, engine: spec.kind.rawValue, polished: result.polished,
                                           app: target.appName, style: result.polished ? target.style.title : nil,
                                           audioMillis: audioMillis, handsFree: handsFree))
                }
                self.done(gen) { self.onResult?(result, target) }
            }
        }
    }

    private func done(_ gen: Int, _ then: () -> Void) {
        guard gen == generation else { return }
        handsFree = false
        state = .idle
        then()
    }

    private func saveRecording(_ samples: [Float]) {
        let dir = models.root.deletingLastPathComponent().appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }
}

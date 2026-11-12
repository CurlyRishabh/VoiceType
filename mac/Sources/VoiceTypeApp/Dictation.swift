import AVFoundation
import Foundation
import VoiceTypeCore

/// record -> VAD auto-stop -> speech-to-text -> Stage 1 (+ Stage 2) -> paste. Main-thread API.
final class Dictation {
    enum State { case idle, listening, transcribing, polishing }

    var onState: ((State) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onResult: ((CleanupResult) -> Void)?
    var onMessage: ((String) -> Void)?

    private(set) var state: State = .idle { didSet { onState?(state) } }

    private let models: ModelStore
    private let speech: SpeechHost
    private let pipeline: CleanupPipeline
    private let polisher: AppleIntelligencePolisher
    private let history: HistoryStore
    private var recorder: Recorder?
    private var context: (startsSentence: Bool, endsSentence: Bool) = (true, true)
    private var generation = 0

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

    func start(autoStop: Bool = true) {
        guard state == .idle else { return }
        let spec = AppSettings.engineSpec
        let slot: ModelSlot = spec.kind == .fastEnglish ? .moonshine : .whisper
        guard models.isReady(slot) else { onMessage?("\(slot.title) not imported — Settings → Models"); return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.start(autoStop: autoStop) } else { self.onMessage?("Microphone access denied") } }
            }
            return
        default:
            onMessage?("Allow the microphone in System Settings → Privacy & Security → Microphone")
            return
        }

        let ctx = Inserter.focusedContext()
        context = (TextJoin.startsSentence(ctx.before), TextJoin.endsSentence(ctx.after))
        warmUp()

        let rec = Recorder(vadModel: models.vadFile)
        rec.autoStop = autoStop
        rec.silenceMillis = max(500, UserDefaults.standard.integer(forKey: Key.silenceMs))
        rec.onLevel = { [weak self] in self?.onLevel?($0) }
        let gen = generation + 1
        generation = gen
        rec.onAutoStop = { [weak self] _ in if self?.generation == gen { self?.stop() } }
        do {
            try rec.start()
        } catch {
            onMessage?("Microphone error: \(error.localizedDescription)")
            return
        }
        recorder = rec
        state = .listening
    }

    /// Hold-to-talk detected: don't auto-stop on pauses.
    func disableAutoStop() { recorder?.autoStop = false }

    func stop() {
        guard state == .listening, let rec = recorder else { return }
        recorder = nil
        state = .transcribing
        let gen = generation
        let captured = rec.stop()
        if !captured.speechDetected || captured.samples.isEmpty {
            finish(gen) { self.onMessage?("Didn't catch that") }
            return
        }
        if UserDefaults.standard.bool(forKey: Key.keepRecordings) { saveRecording(captured.samples) }
        let spec = AppSettings.engineSpec
        let speechMs = captured.speechMillis
        let chunks = DecodePlan.chunks(samples: captured.samples, segments: captured.segments,
                                       whisper: spec.kind == .hindiEnglish, language: spec.language)
        speech.transcribe(spec, chunks: chunks, audioMillis: captured.durationMillis) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async { self.finish(gen) { self.onMessage?(e.localizedDescription) } }
            case .success(let t):
                let raw = HallucinationFilter.clean(t.text, speechMillis: speechMs)
                DispatchQueue.main.async { self.cleanUp(raw, spec: spec, gen: gen) }
            }
        }
    }

    func cancel() {
        generation += 1
        recorder?.cancel()
        recorder = nil
        state = .idle
    }

    private func cleanUp(_ raw: String, spec: EngineSpec, gen: Int) {
        guard gen == generation else { return }
        if raw.isEmpty { finish(gen) { self.onMessage?("Didn't catch that") }; return }
        let settings = AppSettings.cleanup(startsSentence: context.startsSentence, endsSentence: context.endsSentence,
                                           polishAvailable: polisher.isReady)
        if settings.polishEnabled { state = .polishing }
        let pipeline = self.pipeline
        Task {
            let result = await pipeline.process(raw, settings)
            await MainActor.run {
                PerfLog.shared.annotateLatest(polishMillis: settings.polishEnabled ? result.polishMillis : -1, note: result.fallbackReason)
                if UserDefaults.standard.bool(forKey: Key.history), !result.text.isEmpty {
                    self.history.add(.init(date: Date(), text: result.text, raw: raw, engine: spec.kind.rawValue, polished: result.polished))
                }
                self.finish(gen) { self.onResult?(result) }
            }
        }
    }

    private func finish(_ gen: Int, _ then: () -> Void) {
        guard gen == generation else { return }
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

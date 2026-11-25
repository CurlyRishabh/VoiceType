import CSherpaOnnx
import Foundation
import VoiceTypeCore

enum EngineKind: String, CaseIterable {
    case fastEnglish = "fast_english"   // Moonshine Base int8
    case hindiEnglish = "hindi_english" // Whisper small int8
}

struct EngineSpec: Equatable {
    var kind: EngineKind
    /// Whisper language: "en", "hi" or "" (auto-detect).
    var language: String
    /// Inference threads (4 on the phone; up to 8 performance cores on a Mac).
    var threads: Int = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
}

/// Keeps C strings alive for the duration of a sherpa-onnx create call.
private final class CStrings {
    private var ptrs: [UnsafeMutablePointer<CChar>] = []
    func callAsFunction(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        ptrs.append(p)
        return UnsafePointer(p)
    }
    deinit { ptrs.forEach { free($0) } }
}

struct EngineError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

/// A loaded speech model. Not thread-safe: SpeechHost serialises use.
protocol SpeechRecognizing: AnyObject {
    var spec: EngineSpec { get }
    /// Short engine name for logs and the Debug tab.
    var name: String { get }
    /// True when the language is picked per call (whisper.cpp), so dictation and a meeting can use
    /// different languages without reloading the model. sherpa-onnx fixes it when the model loads.
    var languagePerCall: Bool { get }
    /// `language`: "en", "hi" or "" (auto-detect). `prompt`: vocabulary hint (only whisper.cpp uses it).
    func transcribe(_ samples: [Float], prompt: String?, language: String) -> String
    /// The same, with times relative to the start of `samples`, and the language it was decoded in.
    /// Throws when the decoder itself fails (a meeting then counts the chunk as missing).
    func transcribeTimed(_ samples: [Float], prompt: String?, language: String) throws -> (segments: [TimedText], language: String)
}

extension SpeechRecognizing {
    /// In the language the model was loaded for.
    func transcribe(_ samples: [Float], prompt: String?) -> String { transcribe(samples, prompt: prompt, language: spec.language) }
}

enum Recognizers {
    /// Hindi + English uses whisper.cpp (Metal GPU) when a `ggml-*.bin` model is imported, otherwise
    /// sherpa-onnx Whisper. Fast English is always sherpa-onnx Moonshine.
    static func make(_ spec: EngineSpec, modelsRoot: URL) throws -> SpeechRecognizing {
        if let model = whisperCppModel(spec, modelsRoot: modelsRoot) {
            return try WhisperCppRecognizer(spec: spec, model: model)
        }
        return try SherpaRecognizer(spec: spec, modelsRoot: modelsRoot)
    }

    static func whisperCppModel(_ spec: EngineSpec, modelsRoot: URL) -> URL? {
        guard spec.kind == .hindiEnglish else { return nil }
        return ModelLayout.whisperCpp(modelsRoot.appendingPathComponent(ModelSlot.whisper.rawValue))
    }
}

/// sherpa-onnx offline recogniser (Moonshine or Whisper). Not thread-safe: SpeechHost serialises use.
final class SherpaRecognizer: SpeechRecognizing {
    let spec: EngineSpec
    private let recognizer: OpaquePointer
    var name: String { spec.kind == .fastEnglish ? "moonshine" : "whisper-onnx" }

    init(spec: EngineSpec, modelsRoot: URL) throws {
        self.spec = spec
        let s = CStrings()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(sampleRate)
        config.feat_config.feature_dim = 80
        config.decoding_method = s("greedy_search")
        config.model_config.num_threads = Int32(spec.threads)
        config.model_config.provider = s("cpu")

        switch spec.kind {
        case .fastEnglish:
            guard let f = ModelLayout.moonshine(modelsRoot.appendingPathComponent(ModelSlot.moonshine.rawValue)) else {
                throw EngineError("Fast English model not imported (Settings → Models).")
            }
            config.model_config.tokens = s(f.tokens)
            switch f.kind {
            case let .moonshineV1(pre, enc, unc, cac):
                config.model_config.moonshine.preprocessor = s(pre)
                config.model_config.moonshine.encoder = s(enc)
                config.model_config.moonshine.uncached_decoder = s(unc)
                config.model_config.moonshine.cached_decoder = s(cac)
            case let .moonshineV2(enc, merged):
                config.model_config.moonshine.encoder = s(enc)
                config.model_config.moonshine.merged_decoder = s(merged)
            case .whisper: break
            }
        case .hindiEnglish:
            guard let f = ModelLayout.whisper(modelsRoot.appendingPathComponent(ModelSlot.whisper.rawValue)),
                  case let .whisper(enc, dec) = f.kind else {
                throw EngineError("Hindi + English model not imported (Settings → Models).")
            }
            config.model_config.tokens = s(f.tokens)
            config.model_config.model_type = s("whisper")
            config.model_config.whisper.encoder = s(enc)
            config.model_config.whisper.decoder = s(dec)
            config.model_config.whisper.language = s(spec.language) // "" = auto-detect
            config.model_config.whisper.task = s("transcribe")       // translation = decoding as "en"; see AppSettings.engineSpec
            config.model_config.whisper.tail_paddings = -1 // sherpa default; see WhisperBudget for the real fix
        }
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw EngineError("Could not load the speech model (files damaged or incomplete?).")
        }
        recognizer = r
    }

    var languagePerCall: Bool { false }

    func transcribe(_ samples: [Float], prompt: String?, language: String) -> String { transcribe(samples) }

    /// sherpa-onnx gives no times: the chunk is one segment. A decode that fails throws (a meeting
    /// counts the chunk as missing); dictation's `transcribe` still types nothing, as before.
    func transcribeTimed(_ samples: [Float], prompt: String?, language: String) throws -> (segments: [TimedText], language: String) {
        let text = try decode(samples)
        let seconds = Double(samples.count) / Double(sampleRate)
        return (text.isEmpty ? [] : [TimedText(text: text, start: 0, end: seconds)], spec.language)
    }

    func transcribe(_ samples: [Float]) -> String { (try? decode(samples)) ?? "" }

    private func decode(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw EngineError("sherpa-onnx could not create a decoding stream.") }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw EngineError("sherpa-onnx returned no result.") }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
}

/// Silero VAD. Used only from the audio queue.
final class SherpaVAD {
    static let window = 512
    static let minSilence: Float = 0.5
    private let vad: OpaquePointer
    private var pending: [Float] = []

    init?(model: URL) {
        let s = CStrings()
        var c = SherpaOnnxVadModelConfig()
        c.silero_vad.model = s(model.path)
        c.silero_vad.threshold = 0.45
        c.silero_vad.min_silence_duration = Self.minSilence
        c.silero_vad.min_speech_duration = 0.2
        c.silero_vad.window_size = Int32(Self.window)
        c.silero_vad.max_speech_duration = 8 // short segments: Whisper token budget + natural split points
        c.sample_rate = Int32(sampleRate)
        c.num_threads = 1
        c.provider = s("cpu")
        guard let v = SherpaOnnxCreateVoiceActivityDetector(&c, 60) else { return nil }
        vad = v
    }

    func accept(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.window {
            pending.withUnsafeBufferPointer { p in
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, p.baseAddress! + offset, Int32(Self.window))
            }
            offset += Self.window
        }
        pending.removeFirst(offset)
    }

    var isSpeech: Bool { SherpaOnnxVoiceActivityDetectorDetected(vad) != 0 }

    func drain() -> [Segment] {
        var out: [Segment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            if let seg = SherpaOnnxVoiceActivityDetectorFront(vad) {
                out.append(Segment(start: Int(seg.pointee.start), length: Int(seg.pointee.n)))
                SherpaOnnxDestroySpeechSegment(seg)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        return out
    }

    func flush() { SherpaOnnxVoiceActivityDetectorFlush(vad) }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }
}

/// sherpa-onnx offline speaker diarization (pyannote segmentation + CAM++ embeddings + clustering):
/// which stretches of a recording belong to which voice. CPU only; not thread-safe.
final class SherpaDiarizer {
    private let sd: OpaquePointer

    /// `threshold`: clustering distance when the number of people isn't known (lower = more speakers).
    init?(segmentation: URL, embedding: URL, threshold: Float = 0.5) {
        let s = CStrings()
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = s(segmentation.path)
        config.segmentation.num_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        config.segmentation.provider = s("cpu")
        config.embedding.model = s(embedding.path)
        config.embedding.num_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        config.embedding.provider = s("cpu")
        config.clustering.num_clusters = -1
        config.clustering.threshold = threshold
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5
        // The C strings must outlive the create call.
        guard let p = withExtendedLifetime(s, { SherpaOnnxCreateOfflineSpeakerDiarization(&config) }) else { return nil }
        sd = p
    }

    deinit { SherpaOnnxDestroyOfflineSpeakerDiarization(sd) }

    /// 16 kHz mono samples → turns, times in seconds from the start of `samples`.
    func process(_ samples: [Float]) -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let result = samples.withUnsafeBufferPointer { SherpaOnnxOfflineSpeakerDiarizationProcess(sd, $0.baseAddress, Int32($0.count)) }
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard n > 0, let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }
        return (0..<n).map { SpeakerTurn(start: Double(segs[$0].start), end: Double(segs[$0].end), speaker: Int(segs[$0].speaker)) }
    }
}

/// Telling the other people on a call apart, after the transcript is written: reads system.wav
/// (only where the others spoke), finds the voices and rewrites the transcript with "Speaker 1",
/// "Speaker 2"… Synchronous; run it off the main thread.
enum MeetingSpeakers {
    /// The bundled models (app), or `vendor/diarization` next to the package (headless runs).
    static var models: (segmentation: URL, embedding: URL)? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("models/diarization"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/diarization")]
        for case let dir? in candidates {
            let seg = dir.appendingPathComponent("segmentation.onnx"), emb = dir.appendingPathComponent("embedding.onnx")
            if FileManager.default.fileExists(atPath: seg.path), FileManager.default.fileExists(atPath: emb.path) { return (seg, emb) }
        }
        return nil
    }

    /// Longest stretch of the others' speech analysed (memory: about 230 MB of samples an hour).
    static let maxSeconds = 75.0 * 60

    /// The meeting's Others segments labelled by voice, and how many voices; nil when there was
    /// nothing to do (no system audio, too little or too much Others speech, no models). Reads only;
    /// the caller writes the files (on the main thread, so it can't race a rename).
    static func analyze(folder: URL) -> (segments: [TranscriptSegment], speakers: Int)? {
        guard let models, let info = MeetingFiles.readInfo(folder), info.status.hasTranscript else { return nil }
        let segments = MeetingFiles.readSegments(folder)
        guard segments.filter({ $0.channel == .others }).count >= 2,
              let reader = WavReader(url: folder.appendingPathComponent(MeetingChannel.others.fileName)) else { return nil }
        let sr = Double(sampleRate)
        let timeline = SpeakerAssign.Timeline(segments, total: Double(reader.sampleCount) / sr)
        guard timeline.length >= 4 else { return nil }
        guard timeline.length <= maxSeconds else {
            NSLog("VoiceType meeting: %.0f min of the others' speech is too long to tell apart", timeline.length / 60)
            return nil
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(timeline.length * sr) + sampleRate)
        for r in timeline.ranges { samples += reader.read(Int(r.lowerBound * sr)..<Int(r.upperBound * sr)) }
        let t0 = Date()
        guard let diarizer = SherpaDiarizer(segmentation: models.segmentation, embedding: models.embedding) else {
            NSLog("VoiceType meeting: speaker models failed to load")
            return nil
        }
        let turns = timeline.original(diarizer.process(samples))
        let (labelled, count) = SpeakerAssign.assign(segments, turns: turns)
        NSLog("VoiceType meeting: %d voices among the others (%.0fs of speech analysed in %.1fs)", count, timeline.length, Date().timeIntervalSince(t0))
        return (labelled, count)
    }

    /// Writes what `analyze` found (and clears the pending mark). Main thread in the app.
    @discardableResult
    static func apply(_ result: (segments: [TranscriptSegment], speakers: Int)?, folder: URL) -> MeetingInfo? {
        guard var info = MeetingFiles.readInfo(folder) else { return nil }
        info.speakersPending = false
        if let result, info.status.hasTranscript {
            info.speakers = result.speakers
            try? MeetingFiles.writeTranscript(result.segments, info: info, to: folder)
        }
        try? MeetingFiles.writeInfo(info, to: folder)
        return info
    }

    /// Headless: analyse and write in one go.
    static func identify(folder: URL) -> MeetingInfo? {
        let found = analyze(folder: folder)
        return found == nil ? nil : apply(found, folder: folder)
    }
}

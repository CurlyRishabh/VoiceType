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

/// sherpa-onnx offline recogniser (Moonshine or Whisper). Not thread-safe: SpeechHost serialises use.
final class SherpaRecognizer {
    let spec: EngineSpec
    private let recognizer: OpaquePointer

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
            config.model_config.whisper.task = s("transcribe")       // never "translate"
            config.model_config.whisper.tail_paddings = -1 // sherpa default; see WhisperBudget for the real fix
        }
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw EngineError("Could not load the speech model (files damaged or incomplete?).")
        }
        recognizer = r
    }

    func transcribe(_ samples: [Float]) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
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

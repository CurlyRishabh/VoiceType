import Foundation
import VoiceTypeCore
import whisper

/// whisper.cpp on the Apple-silicon GPU (Metal) for the Hindi + English engine. Compared with
/// sherpa-onnx Whisper it runs larger models (large-v3-turbo) fast enough for dictation, has no
/// 6-tokens-per-second output cap, and accepts a vocabulary prompt.
/// Not thread-safe: SpeechHost serialises use.
final class WhisperCppRecognizer: SpeechRecognizing {
    let spec: EngineSpec
    let name: String
    private let ctx: OpaquePointer

    init(spec: EngineSpec, model: URL) throws {
        Self.routeLogs()
        self.spec = spec
        name = "whisper.cpp " + ModelLayout.whisperCppName(model)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let c = whisper_init_from_file_with_params(model.path, params) else {
            throw EngineError("Could not load \(model.lastPathComponent) (damaged, or not a whisper.cpp model?).")
        }
        ctx = c
    }

    /// The language comes with each call (not from `spec`), so one loaded model serves dictation and
    /// a meeting in different languages.
    var languagePerCall: Bool { true }

    /// Dictation: a failed decode types nothing, as before.
    func transcribe(_ samples: [Float], prompt: String?, language: String) -> String {
        ((try? transcribeTimed(samples, prompt: prompt, language: language))?.segments ?? []).map(\.text).joined(separator: " ")
    }

    /// Whisper's own segments with their times (`whisper_full_get_segment_t0/t1`, in 10 ms units),
    /// relative to the start of `samples`.
    func transcribeTimed(_ samples: [Float], prompt: String?, language: String) throws -> (segments: [TimedText], language: String) {
        guard !samples.isEmpty else { return ([], language) }
        let prompt = (prompt?.isEmpty ?? true) ? nil : prompt
        let language = language.isEmpty ? detectLanguage(samples) : language
        let segments = try decode(samples, prompt: prompt, language: language)
        // Short clips (Hindi forced to English most of all) can come back as the prompt itself
        // instead of the speech: decode once more without it.
        if let prompt, WhisperPrompt.isEcho(segments.map(\.text).joined(separator: " "), prompt: prompt) {
            return (try decode(samples, prompt: nil, language: language), language)
        }
        return (segments, language)
    }

    private func decode(_ samples: [Float], prompt: String?, language: String) throws -> [TimedText] {
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(spec.threads)
        p.translate = false          // large-v3-turbo ignores Whisper's translate task; see AppSettings.engineSpec
        p.no_context = true          // each chunk stands alone, like the sherpa path
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.suppress_blank = true
        p.suppress_nst = true        // drop "[Music]"-style non-speech tokens
        let status = language.withCString { lang in
            Self.withOptionalCString(prompt) { promptPtr in
                p.language = lang
                p.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else {
            NSLog("VoiceType: whisper.cpp decode failed (%d)", status)
            throw EngineError("whisper.cpp could not decode this audio (error \(status)).")
        }
        return (0..<whisper_full_n_segments(ctx)).compactMap { i in
            guard let c = whisper_full_get_segment_text(ctx, i) else { return nil }
            let text = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedText(text: text, start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                             end: Double(whisper_full_get_segment_t1(ctx, i)) / 100)
        }
    }

    /// "Both": score the languages ourselves and let LanguageSelection choose between Hindi and
    /// English, instead of Whisper's own pick among ~100. Same cost as its auto-detect: one encoder pass.
    private func detectLanguage(_ samples: [Float]) -> String {
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let threads = Int32(spec.threads)
        let ok = samples.withUnsafeBufferPointer { whisper_pcm_to_mel(ctx, $0.baseAddress, Int32($0.count), threads) } == 0
            && whisper_lang_auto_detect(ctx, 0, threads, &probs) >= 0
        guard ok else { return "auto" } // could not score: leave it to Whisper, as before
        return LanguageSelection.decodeLanguage { probs[Int(whisper_lang_id($0))] }
    }

    deinit { whisper_free(ctx) }

    private static func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let s else { return body(nil) }
        return s.withCString { body($0) }
    }

    /// whisper.cpp and ggml log every load step to stderr; keep only errors, in the system log.
    private static let routeLogsOnce: Void = {
        let callback: ggml_log_callback = { level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            NSLog("whisper.cpp: %@", String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        whisper_log_set(callback, nil)
        ggml_log_set(callback, nil)
    }()

    private static func routeLogs() { _ = routeLogsOnce }
}

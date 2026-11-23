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

    func transcribe(_ samples: [Float], prompt: String?) -> String {
        guard !samples.isEmpty else { return "" }
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
        let prompt = (prompt?.isEmpty ?? true) ? nil : prompt
        let language = spec.language.isEmpty ? detectLanguage(samples) : spec.language

        func decode(_ prompt: String?) -> String {
            let status = language.withCString { lang in
                Self.withOptionalCString(prompt) { promptPtr in
                    p.language = lang
                    p.initial_prompt = promptPtr
                    return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
                }
            }
            guard status == 0 else {
                NSLog("VoiceType: whisper.cpp decode failed (%d)", status)
                return ""
            }
            return (0..<whisper_full_n_segments(ctx))
                .compactMap { whisper_full_get_segment_text(ctx, $0).map { String(cString: $0) } }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = decode(prompt)
        // Short clips (Hindi forced to English most of all) can come back as the prompt itself
        // instead of the speech: decode once more without it.
        if let prompt, WhisperPrompt.isEcho(text, prompt: prompt) { return decode(nil) }
        return text
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

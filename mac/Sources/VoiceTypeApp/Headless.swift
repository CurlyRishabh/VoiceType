import AVFoundation
import Foundation
import VoiceTypeCore

/// Command-line modes of the (unsandboxed, dev) binary: --selftest and --bench.
enum Headless {
    /// Any file Core Audio reads (wav, flac, mp3, m4a) -> 16 kHz mono Float32.
    static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard file.length > 0 else { return [] }
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * Double(sampleRate) / file.processingFormat.sampleRate) + 64)!
        var fed = false
        conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return src
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Silero VAD over a whole clip, exactly like live dictation (nil when no VAD model).
    static func segments(_ samples: [Float], modelsRoot: URL) -> [Segment]? {
        guard let url = ModelLayout.vad(modelsRoot.appendingPathComponent("vad")), let vad = SherpaVAD(model: url) else { return nil }
        vad.accept(samples); vad.flush()
        return vad.drain()
    }

    static func prompt() -> String? {
        ProcessInfo.processInfo.environment["VOICETYPE_PROMPT"].flatMap { WhisperPrompt.build($0.components(separatedBy: ",")) }
    }

    /// Speech -> text the way the app does it (VAD, chunking, decode, hallucination filter), minus clean-up.
    static func recognize(_ samples: [Float], with rec: SpeechRecognizing, modelsRoot: URL, prompt: String?) -> String {
        let spec = rec.spec
        let cpp = Recognizers.whisperCppModel(spec, modelsRoot: modelsRoot) != nil
        let chunks = DecodePlan.chunks(samples: samples, segments: segments(samples, modelsRoot: modelsRoot),
                                       whisper: spec.kind == .hindiEnglish, language: spec.language, tokenBudget: !cpp)
        return HallucinationFilter.clean(chunks.map { rec.transcribe($0, prompt: prompt) }.joined(separator: " "), speechMillis: 5000)
    }

    static func spec(engine: String, language: String) -> EngineSpec {
        EngineSpec(kind: engine == "moonshine" ? .fastEnglish : .hindiEnglish, language: language == "auto" ? "" : language)
    }

    /// VoiceType --bench <manifest.tsv> <modelsDir> <en|hi|auto> <moonshine|whisper> <out.tsv>
    /// Manifest: one "audio path<TAB>reference transcript" per line. Writes one result row per clip
    /// and prints a SUMMARY line with corpus WER / CER and real-time factor.
    static func bench(_ args: [String]) -> Never {
        guard args.count >= 7 else {
            print("usage: VoiceType --bench <manifest.tsv> <modelsDir> <en|hi|auto> <moonshine|whisper> <out.tsv>")
            exit(2)
        }
        let manifest = URL(fileURLWithPath: args[2]), models = URL(fileURLWithPath: args[3])
        let language = args[4], engine = args[5], outURL = URL(fileURLWithPath: args[6])
        let metricLang = language == "auto" ? "hi" : language
        do {
            let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let spec = spec(engine: engine, language: language)
            let t0 = Date()
            let rec = try Recognizers.make(spec, modelsRoot: models)
            let load = Date().timeIntervalSince(t0)
            let prompt = prompt()
            var wer = ASRMetrics.Score(), cer = ASRMetrics.Score()
            var audioSec = 0.0, decodeSec = 0.0
            var rows = ["id\taudio_s\tdecode_s\tword_errors\tref_words\tchar_errors\tref_chars\treference\thypothesis"]
            for (i, line) in lines.enumerated() {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let url = URL(fileURLWithPath: parts[0]), reference = parts[1]
                let samples = try loadSamples(url)
                let start = Date()
                let hypothesis = recognize(samples, with: rec, modelsRoot: models, prompt: prompt)
                let took = Date().timeIntervalSince(start)
                let secs = Double(samples.count) / Double(sampleRate)
                let w = ASRMetrics.wer(reference: reference, hypothesis: hypothesis, language: metricLang)
                let c = ASRMetrics.cer(reference: reference, hypothesis: hypothesis, language: metricLang)
                wer = wer + w; cer = cer + c; audioSec += secs; decodeSec += took
                let clean: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                rows.append([url.deletingPathExtension().lastPathComponent, String(format: "%.2f", secs), String(format: "%.3f", took),
                             "\(w.errors)", "\(w.refCount)", "\(c.errors)", "\(c.refCount)", clean(reference), clean(hypothesis)].joined(separator: "\t"))
                if (i + 1) % 10 == 0 || i + 1 == lines.count {
                    FileHandle.standardError.write(Data(String(format: "  %@: %d/%d clips, WER so far %.1f%%\n", rec.name, i + 1, lines.count, wer.rate * 100).utf8))
                }
            }
            try (rows.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
            print(String(format: "SUMMARY\tengine=%@\tlang=%@\tclips=%d\taudio=%.0fs\tdecode=%.1fs\tRTF=%.3f\tload=%.1fs\tWER=%.2f\tCER=%.2f\tprompt=%@",
                         rec.name, language, rows.count - 1, audioSec, decodeSec, decodeSec / max(audioSec, 0.001), load,
                         wer.rate * 100, cer.rate * 100, prompt == nil ? "no" : "yes"))
            exit(0)
        } catch {
            print("BENCH FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}

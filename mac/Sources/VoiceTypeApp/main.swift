import AppKit
import AVFoundation
import Foundation
import VoiceTypeCore

// Headless self-test, used by scripts/build-dmg.sh to verify the speech + clean-up stack on real
// audio before packaging:  VoiceType --selftest <modelsDir> <file.wav> <en|hi|auto> [moonshine|whisper]
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--selftest" {
    let models = URL(fileURLWithPath: CommandLine.arguments[2])
    let wav = URL(fileURLWithPath: CommandLine.arguments[3])
    let lang = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "en"
    let engine = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : (lang == "en" ? "moonshine" : "whisper")
    do {
        let file = try AVAudioFile(forReading: wav)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 64)!
        var fed = false
        conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return src }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))

        // VAD over the clip, exactly like live dictation.
        var segments: [Segment]? = nil
        if let vadURL = ModelLayout.vad(models.appendingPathComponent("vad")), let vad = SherpaVAD(model: vadURL) {
            vad.accept(samples); vad.flush(); segments = vad.drain()
        }
        let spec = EngineSpec(kind: engine == "moonshine" ? .fastEnglish : .hindiEnglish, language: lang == "auto" ? "" : lang)
        let chunks = DecodePlan.chunks(samples: samples, segments: segments, whisper: spec.kind == .hindiEnglish, language: spec.language)
        let t0 = Date()
        let rec = try SherpaRecognizer(spec: spec, modelsRoot: models)
        let load = Date().timeIntervalSince(t0)
        let t1 = Date()
        let raw = HallucinationFilter.clean(chunks.map(rec.transcribe).joined(separator: " "), speechMillis: 5000)
        let decode = Date().timeIntervalSince(t1)
        let audio = Double(samples.count) / Double(sampleRate)
        var settings = CleanupSettings()
        settings.script = .latin
        let latin = RuleCleaner().clean(Transliterator.toLatin(raw), settings.options)
        print("threads=\(spec.threads)")
        print("engine=\(engine) lang=\(lang) audio=\(String(format: "%.2f", audio))s segments=\(segments?.count ?? -1) chunks=\(chunks.count)")
        print("load=\(String(format: "%.2f", load))s decode=\(String(format: "%.2f", decode))s RTF=\(String(format: "%.3f", decode / max(audio, 0.001)))")
        print("RAW:     \(raw)")
        print("CLEANED: \(latin)")
        exit(0)
    } catch {
        print("SELFTEST FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

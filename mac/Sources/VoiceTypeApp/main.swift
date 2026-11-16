import AppKit
import AVFoundation
import Foundation
import VoiceTypeCore

// Headless self-test, used by scripts/build-dmg.sh to verify the speech + clean-up stack on real
// audio before packaging:  VoiceType --selftest <modelsDir> <file.wav> <en|hi|auto> [moonshine|whisper]
// Benchmark on real audio: VoiceType --bench <manifest.tsv> <modelsDir> <lang> <engine> <out.tsv> (see scripts/bench-asr.sh).
// Set VOICETYPE_PROMPT="Term one, Term two" to test the whisper.cpp vocabulary prompt.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--bench" {
    Headless.bench(CommandLine.arguments)
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--selftest" {
    let models = URL(fileURLWithPath: CommandLine.arguments[2])
    let wav = URL(fileURLWithPath: CommandLine.arguments[3])
    let lang = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "en"
    let engine = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : (lang == "en" ? "moonshine" : "whisper")
    do {
        let samples = try Headless.loadSamples(wav)
        let spec = Headless.spec(engine: engine, language: lang)
        let prompt = Headless.prompt()
        let t0 = Date()
        let rec = try Recognizers.make(spec, modelsRoot: models)
        let load = Date().timeIntervalSince(t0)
        let t1 = Date()
        let raw = Headless.recognize(samples, with: rec, modelsRoot: models, prompt: prompt)
        let decode = Date().timeIntervalSince(t1)
        let audio = Double(samples.count) / Double(sampleRate)
        var settings = CleanupSettings()
        settings.script = .latin
        let latin = RuleCleaner().clean(Transliterator.toLatin(raw), settings.options)
        print("threads=\(spec.threads)")
        print("model=\(rec.name) prompt=\(prompt ?? "-")")
        print("engine=\(engine) lang=\(lang) audio=\(String(format: "%.2f", audio))s")
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

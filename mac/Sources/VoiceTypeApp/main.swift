import AppKit
import AVFoundation
import Foundation
import VoiceTypeCore

// Headless modes of the dev binary, for testing the speech stack on real audio:
//   VoiceType --selftest <modelsDir> <audio> [en|hi|auto] [whisper|moonshine] [--translate] [--devanagari]
//   VoiceType --bench <manifest.tsv> <modelsDir> <lang> <engine> <out.tsv> [--translate]  (scripts/bench-asr.sh)
//   scripts/test-audio.sh runs a clip through every language/translate mode.
//   VoiceType --meeting <mic.wav> <system.wav> [modelsDir] [en|hi|auto]  (scripts/test-meeting.sh)
// Set VOICETYPE_PROMPT="Term one, Term two" to test the whisper.cpp vocabulary prompt.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--meeting" {
    Headless.meeting(CommandLine.arguments)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--bench" {
    Headless.bench(CommandLine.arguments)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--selftest" {
    Headless.selftest(CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

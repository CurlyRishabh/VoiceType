import Foundation
import Testing
@testable import VoiceTypeCore

struct DictionaryTests {
    func dict(_ pairs: (String, String)...) -> PersonalDictionary { PersonalDictionary(pairs.map { .init($0.0, $0.1) }) }

    @Test func caseInsensitive() { #expect(dict(("acme", "Acme")).apply("I work at acme and ACME is great") == "I work at Acme and Acme is great") }
    @Test func wholeWordsOnly() { #expect(dict(("acme", "Acme")).apply("acmefied stays") == "acmefied stays") }
    @Test func phraseFlexibleSpacing() { #expect(dict(("acme h q", "AcmeHQ")).apply("Ask acme  h q today") == "Ask AcmeHQ today") }
    @Test func longerPhraseWins() { #expect(dict(("new york", "New York"), ("new york times", "NYT")).apply("new york times and new york") == "NYT and New York") }
    @Test func literalReplacement() { #expect(dict(("five bucks", "$5")).apply("cost five bucks") == "cost $5") }
    @Test func devanagari() { #expect(dict(("एक्मे", "Acme")).apply("एक्मे में") == "Acme में") }
    @Test func roundTrip() {
        let d = dict(("acme", "Acme"), ("gpt", "GPT"))
        #expect(PersonalDictionary.parse(d.serialize()).entries == d.entries)
    }
    @Test func parseIgnoresJunk() {
        #expect(PersonalDictionary.parse("a\tb\nbroken line\n\n c \t d ").entries == [.init("a", "b"), .init("c", "d")])
    }
    @Test func plusReplaces() {
        let d = dict(("acme", "Acme")).plus(.init("ACME", "ACME Inc"))
        #expect(d.entries.count == 1 && d.entries[0].to == "ACME Inc")
    }
    @Test func minusRemoves() { #expect(dict(("a", "b")).minus("A").isEmpty) }
}

struct PolishPromptGuardTests {
    @Test func promptHasRulesAndDelimiters() {
        let r = PolishPrompt.build("hello there", style: .professional, script: .latin)
        #expect(r.instructions.contains("Never translate"))
        #expect(r.instructions.contains("professional email"))
        #expect(r.userMessage == "<<<\nhello there\n>>>")
    }
    @Test func notesAndCasual() {
        #expect(PolishPrompt.build("a", style: .notes, script: .latin).instructions.contains("bullet"))
        #expect(PolishPrompt.build("a", style: .casual, script: .latin).instructions.contains("casual"))
    }
    @Test func scriptInstructions() {
        #expect(PolishPrompt.build("kal meeting hai, main nahi aa paunga", style: .casual, script: .latin).instructions.contains("Latin script"))
        #expect(PolishPrompt.build("कल मीटिंग है", style: .casual, script: .devanagari).instructions.contains("Devanagari"))
    }
    @Test func tokenBudget() {
        #expect(PolishPrompt.build("", style: .casual, script: .latin).maxOutputTokens == 48)
        #expect(PolishPrompt.build(String(repeating: "x", count: 5000), style: .casual, script: .latin).maxOutputTokens == 512)
    }
    @Test(arguments: [
        "Here is the cleaned text:\nHello there.", "<<<\nHello there.\n>>>", "```\nHello there.\n```",
        "\"Hello there.\"", "Sure! Here's the corrected text: Hello there.",
    ]) func extractStripsWrappers(_ raw: String) { #expect(PolishPrompt.extract(raw) == "Hello there.") }

    func ok(_ i: String, _ o: String, _ s: PolishStyle = .casual) -> Bool { PolishGuard.check(input: i, output: o, style: s) == .accept }
    @Test func guardAccepts() {
        #expect(ok("me and him goes to the store tomorrow", "He and I are going to the store tomorrow."))
        #expect(ok("kal miting hai office mein", "Kal meeting hai office mein."))
        #expect(ok("buy milk and eggs and call mom", "- Buy milk and eggs\n- Call mom", .notes))
    }
    @Test func guardRejects() {
        #expect(!ok("hello", "  "))
        #expect(!ok("what is the capital of France", "The capital of France is Paris, a city known for the Eiffel Tower and its museums and long history."))
        #expect(!ok("send the file", "Sure! I have sent the file."))
        #expect(!ok("मैं कल ऑफिस आऊँगा", "I will come to the office tomorrow."))
        #expect(!ok("I will come to the office tomorrow", "मैं कल ऑफिस आऊँगा।"))
        #expect(!ok("please remember to send the quarterly report to the whole finance team", "Send it."))
        #expect(!ok("thanks for the update", "Thanks for the update! I really appreciate your hard work and dedication on this project."))
    }
}

final class FakePolisher: Polisher, @unchecked Sendable {
    let reply: @Sendable (PolishRequest) async throws -> String
    var isReady: Bool
    var warmUps = 0
    var last: PolishRequest?
    init(ready: Bool = true, _ reply: @escaping @Sendable (PolishRequest) async throws -> String) { isReady = ready; self.reply = reply }
    func warmUp() { warmUps += 1 }
    func polish(_ r: PolishRequest) async throws -> String { last = r; return try await reply(r) }
}

struct PipelineTests {
    var on: CleanupSettings { var s = CleanupSettings(); s.polishEnabled = true; return s }

    @Test func stage1WhenPolishOff() async {
        let p = FakePolisher { _ in "NO" }
        let r = await CleanupPipeline(polisher: p).process("um hello world", CleanupSettings())
        #expect(r.text == "Hello world." && !r.polished && p.last == nil)
    }
    @Test func usesPolish() async {
        let p = FakePolisher { _ in "Hello, world." }
        let r = await CleanupPipeline(polisher: p).process("um hello world", on)
        #expect(r.stage1 == "Hello world." && r.text == "Hello, world." && r.polished)
    }
    @Test func timesOutQuickly() async {
        let p = FakePolisher { _ in try await Task.sleep(for: .seconds(10)); return "late" }
        let start = ContinuousClock.now
        let r = await CleanupPipeline(polisher: p, timeout: .milliseconds(200)).process("hello world", on)
        #expect(r.text == "Hello world." && !r.polished)
        #expect(r.fallbackReason?.contains("timed out") == true)
        #expect(ContinuousClock.now - start < .milliseconds(1500))
    }
    @Test func timesOutEvenIfPolisherIgnoresCancellation() async {
        let p = FakePolisher { _ in
            // Blocks a thread and never checks for cancellation.
            Thread.sleep(forTimeInterval: 2)
            return "late"
        }
        let start = ContinuousClock.now
        let r = await CleanupPipeline(polisher: p, timeout: .milliseconds(200)).process("hello world", on)
        #expect(r.text == "Hello world." && !r.polished)
        #expect(ContinuousClock.now - start < .milliseconds(1000))
    }

    @Test func errorFallsBack() async {
        struct Boom: Error {}
        let r = await CleanupPipeline(polisher: FakePolisher { _ in throw Boom() }).process("hello world", on)
        #expect(r.text == "Hello world." && r.fallbackReason != nil)
    }
    @Test func notReadyWarmsUp() async {
        let p = FakePolisher(ready: false) { _ in "x" }
        let r = await CleanupPipeline(polisher: p).process("hello world", on)
        #expect(r.text == "Hello world." && p.warmUps == 1)
    }
    @Test func rejectsTranslation() async {
        let r = await CleanupPipeline(polisher: FakePolisher { _ in "मैं कल आऊँगा।" }).process("main kal aaunga", on)
        #expect(r.text == "Main kal aaunga." && r.fallbackReason?.contains("rejected") == true)
    }
    @Test func dictionaryWins() async {
        var s = on
        s.options.dictionary = PersonalDictionary([.init("acme", "Acme")])
        let r = await CleanupPipeline(polisher: FakePolisher { _ in "I work at Acm and acme." }).process("i work at acme", s)
        #expect(r.text == "I work at Acm and Acme.")
    }
    @Test func transliterates() async {
        #expect(await CleanupPipeline(polisher: nil).process("कल मीटिंग है", CleanupSettings()).text == "Kal meeting hai.")
        var s = CleanupSettings(); s.script = .devanagari
        #expect(await CleanupPipeline(polisher: nil).process("कल मीटिंग है", s).text == "कल मीटिंग है।")
    }
    @Test func midSentenceLowercase() async {
        var s = on; s.options.startsSentence = false
        let r = await CleanupPipeline(polisher: FakePolisher { _ in "And then we left." }).process("and then we left", s)
        #expect(r.text == "and then we left.")
    }
}

struct TextJoinTests {
    @Test func sentences() {
        #expect(TextJoin.startsSentence(nil) && TextJoin.startsSentence("Done. ") && TextJoin.startsSentence("Line\n"))
        #expect(!TextJoin.startsSentence("I went to"))
        #expect(TextJoin.endsSentence("") && TextJoin.endsSentence("  \nnext") && !TextJoin.endsSentence(" and more"))
    }
    @Test func pad() {
        #expect(TextJoin.pad("world", before: "hello", after: nil) == " world")
        #expect(TextJoin.pad("world", before: "hello ", after: nil) == "world")
        #expect(TextJoin.pad("big", before: "a ", after: "house") == "big ")
        #expect(TextJoin.pad("big", before: "a", after: ", ok") == " big")
    }
}

struct AudioLogicTests {
    let s = sampleRate
    @Test func noVad() {
        let p = AudioChunker.plan(total: s * 60, segments: nil)
        #expect(p.count == 3 && p.allSatisfy { $0.count <= AudioChunker.maxChunk } && p.map(\.count).reduce(0, +) == s * 60)
    }
    @Test func noSpeech() { #expect(AudioChunker.plan(total: s * 5, segments: []).isEmpty) }
    @Test func merges() { #expect(AudioChunker.plan(total: s * 10, segments: [.init(start: s, length: s), .init(start: 3 * s, length: s)]).count == 1) }
    @Test func keepsApart() { #expect(AudioChunker.plan(total: s * 20, segments: [.init(start: s, length: s), .init(start: 10 * s, length: s)]).count == 2) }
    @Test func hallucinations() {
        #expect(HallucinationFilter.clean("[Music] Hello (upbeat music) there ♪", speechMillis: 5000) == "Hello there")
        #expect(HallucinationFilter.clean("Thanks for watching!", speechMillis: 900) == "")
        #expect(HallucinationFilter.clean("Thank you.", speechMillis: 100) == "")
        #expect(HallucinationFilter.clean("Thank you.", speechMillis: 700) == "Thank you.")
    }
    @Test func collapsesDecoderLoops() {
        #expect(HallucinationFilter.collapseRepeats("अप आप आप आप आप आप आप") == "अप आप")
        #expect(HallucinationFilter.collapseRepeats("go to the go to the go to the go to the end") == "go to the end")
        #expect(HallucinationFilter.collapseRepeats("very very good") == "very very good") // real speech untouched
    }
    @Test func whisperBudgetPadding() {
        #expect(!WhisperBudget.needsPadding(whisper: true, language: "en"))
        #expect(WhisperBudget.needsPadding(whisper: true, language: "hi") && WhisperBudget.needsPadding(whisper: true, language: ""))
        #expect(!WhisperBudget.needsPadding(whisper: false, language: "hi"))
        // 2 s of speech -> 7 s, so 6 tok/s * 7 s = 42 tokens >= 21 tok/s * 2 s
        #expect(WhisperBudget.paddedLength(2 * s) == 7 * s)
        // never beyond Whisper's window
        #expect(WhisperBudget.paddedLength(20 * s) == 29 * s)
        let chunks = DecodePlan.chunks(samples: [Float](repeating: 0.1, count: 20 * s), segments: nil, whisper: true, language: "hi")
        #expect(chunks.count == 3 && chunks.allSatisfy { $0.count <= 29 * s })
        #expect(DecodePlan.chunks(samples: [Float](repeating: 0.1, count: 20 * s), segments: nil, whisper: false, language: "en").count == 1)
    }
    @Test func modelLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["small-encoder.onnx", "small-encoder.int8.onnx", "small-decoder.int8.onnx", "small-tokens.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        let w = ModelLayout.whisper(dir)
        guard case .whisper(let enc, _)? = w?.kind else { Issue.record("no whisper"); return }
        #expect(enc.hasSuffix("small-encoder.int8.onnx"))
    }
}

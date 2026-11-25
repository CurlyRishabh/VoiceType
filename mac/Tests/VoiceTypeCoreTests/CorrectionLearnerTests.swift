import Testing
@testable import VoiceTypeCore

@Suite struct CorrectionLearnerTests {
    static let vocabulary: Set<String> = ["the", "and", "fix", "fixes", "report", "reports", "affect", "effect", "then", "there",
                                          "their", "walk", "walked", "it", "works", "build", "get", "hub", "push", "to", "today"]

    func learn(_ typed: String, _ now: String, before: String = "Hi. ", after: String = "") -> [String] {
        CorrectionLearner.corrections(typed: typed, before: before, after: after, now: before + now + after,
                                      isWord: { Self.vocabulary.contains($0) }).map { "\($0.from)→\($0.to)" }
    }

    @Test func sentenceCapitalNotLearned() { #expect(learn("It works the build passed.", "It works. The build passed.").isEmpty) }
    @Test func grammarNotLearned() {
        #expect(learn("Please fix the bug.", "Please fixes the bug.").isEmpty)
        #expect(learn("I walk there.", "I walked there.").isEmpty)
        #expect(learn("It will affect us.", "It will effect us.").isEmpty)
        #expect(learn("Put it then.", "Put it there.").isEmpty)
    }
    @Test func innerCapitalLearned() { #expect(learn("Buy an iphone now.", "Buy an iPhone now.") == ["iphone→iPhone"]) }

    @Test func nameRespelling() { #expect(learn("Thanks Rishab for the fix.", "Thanks Rishabh for the fix.") == ["Rishab→Rishabh"]) }
    @Test func splitWordJoined() { #expect(learn("Push it to get hub today.", "Push it to GitHub today.") == ["get hub→GitHub"]) }
    @Test func capitalsOnly() { #expect(learn("We use kubernetes here.", "We use Kubernetes here.") == ["kubernetes→Kubernetes"]) }
    @Test func rewriteIsNotLearned() { #expect(learn("Send the report tomorrow.", "Send the invoice tomorrow.").isEmpty) }
    @Test func smallWordsIgnored() { #expect(learn("Put it in a box.", "Put it in the box.").isEmpty) }
    @Test func additionsAndDeletionsIgnored() {
        #expect(learn("Call me later.", "Call me much later please.").isEmpty)
        #expect(learn("Call me later today.", "Call me.").isEmpty)
    }
    @Test func unchangedTeachesNothing() { #expect(learn("All good.", "All good.").isEmpty) }
    @Test func surroundingTextChangedMeansNoGuess() {
        #expect(CorrectionLearner.corrections(typed: "Rishab", before: "Hi ", after: "", now: "Hello Rishabh").isEmpty)
    }
    @Test func textAfterCursorKept() { #expect(learn("ask Rishab", "ask Rishabh", before: "Please ", after: " now.") == ["Rishab→Rishabh"]) }
    @Test func punctuationAroundWordsIgnored() { #expect(learn("Ping Rishab, please.", "Ping Rishabh, please.") == ["Rishab→Rishabh"]) }
    @Test func knownEntrySkipped() {
        let known = PersonalDictionary([.init("Rishab", "Rishabh")])
        #expect(CorrectionLearner.corrections(typed: "Rishab", before: "", after: "", now: "Rishabh", known: known).isEmpty)
    }
}

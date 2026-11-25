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

    @Test func shortenedName() { #expect(learn("Let's send this draft to Shashi.", "Let's send this draft to Sasi.", before: "") == ["Shashi→Sasi"]) }
    @Test func shortenedNameInChatBox() { #expect(learn("send this draft to Sashi", "send this draft to Sasi", before: "") == ["Sashi→Sasi"]) }
    @Test func wordStuckOnNotLearned() {
        #expect(learn("send this draft to Shashi", "send this draft to ShashiSasi", before: "").isEmpty)
        #expect(learn("ping Rishabh today", "ping Rish today", before: "").isEmpty)
    }
    @Test func cutShortNotLearned() { #expect(learn("Thanks Rishab for the fix.", "Thanks Rish for the fix.").isEmpty) }
    @Test func namesCheckedInLowerCase() {
        // The macOS checker accepts most capitalised names; only the lower-case form is asked.
        let checker: (String) -> Bool = { $0.first?.isUppercase == true || Self.vocabulary.contains($0) }
        #expect(CorrectionLearner.corrections(typed: "send it to Shashi", before: "", after: "", now: "send it to Sasi",
                                              isWord: checker).map(\.to) == ["Sasi"])
    }
    @Test func dictationStillThere() {
        #expect(CorrectionLearner.dictationStillThere("Hi. send it to Sasi", before: "Hi. ", after: ""))
        #expect(!CorrectionLearner.dictationStillThere("", before: "", after: "")) // chat box sent
        #expect(!CorrectionLearner.dictationStillThere("Hi. ", before: "Hi. ", after: "")) // dictation deleted
        #expect(!CorrectionLearner.dictationStillThere("Hello. send it", before: "Hi. ", after: "")) // text before changed
        #expect(!CorrectionLearner.dictationStillThere("Hi. send it", before: "Hi. ", after: " Bye")) // text after changed
    }
    @Test func sentChatBoxReadsAsLineBreak() {
        // An empty rich-text box (Slack, T3 Code) reads as a line break after Return.
        #expect(!CorrectionLearner.dictationStillThere("\n", before: "", after: ""))
        #expect(!CorrectionLearner.dictationStillThere("Hi.\n \n", before: "Hi.", after: ""))
        #expect(CorrectionLearner.dictationStillThere("Kritant\n", before: "", after: ""))
    }
    @Test func pasteLocatedInEmptyRichTextBox() {
        // Empty Slack/T3 box: "\n" with the cursor before it; the line break is gone once there is text.
        let spot = CorrectionLearner.locate("Hi, my name is Kreta nt.", was: "\n", now: "Hi, my name is Kreta nt.")
        #expect(spot?.before == "" && spot?.middle == "Hi, my name is Kreta nt." && spot?.after == "")
    }
    @Test func pasteLocatedOnSecondLine() {
        // Chromium puts the cursor one short per line break above it ("…\nHi|." ): the text says where the paste went.
        let was = "Hi, my name is Rishabh.\nHi."
        let spot = CorrectionLearner.locate("Hi, my name is Kreta nt.", was: was, now: was + "Hi, my name is Kreta nt.")
        #expect(spot?.before == was && spot?.after == "")
        let fixed = was + "Hi, my name is Kritant."
        #expect(CorrectionLearner.corrections(typed: spot!.middle, before: spot!.before, after: spot!.after, now: fixed)
                    .map { "\($0.from)→\($0.to)" } == ["Kreta nt→Kritant"])
    }
    @Test func pasteLocatedMidText() {
        let spot = CorrectionLearner.locate(" and Rishab", was: "Ask Sasi today.", now: "Ask Sasi and Rishab today.")
        // Where a space goes is ambiguous; either way the three parts make up the field.
        #expect(spot?.before == "Ask Sasi " && spot?.middle == "and Rishab " && spot?.after == "today.")
        // A paste that turned line breaks into paragraphs, or spacing changed, still counts.
        #expect(CorrectionLearner.locate("one\ntwo", was: "", now: "one\n\ntwo") != nil)
    }
    @Test func pasteNotLandedYet() {
        #expect(CorrectionLearner.locate("Hi there", was: "\n", now: "\n") == nil)
        #expect(CorrectionLearner.locate("Hi there", was: "", now: "Hi th") == nil)
        #expect(CorrectionLearner.locate("Hi there", was: "Draft", now: "Draft something else") == nil)
    }
    @Test func fixOfLearnedWordChangesTheEntry() {
        let d = PersonalDictionary([.init("Kreta nt", "Kritnat"), .init("get hub", "GitHub")])
        #expect(d.learning(.init("Kritnat", "Kritant")).entries == [.init("get hub", "GitHub"), .init("Kreta nt", "Kritant")])
        // Back to what was heard: the entry goes, nothing turns "Rishabh" into "Rishab" from now on.
        #expect(PersonalDictionary([.init("Rishab", "Rishabh")]).learning(.init("Rishabh", "Rishab")).isEmpty)
        #expect(PersonalDictionary.empty.learning(.init("Shashi", "Sasi")).entries == [.init("Shashi", "Sasi")])
    }
    @Test func secondDictationInSameField() {
        // First dictation "send this to Shashi", fixed to "Sasi", then " and copy Rishab" dictated after it.
        let joined = CorrectionLearner.joinDictations(before: "Hi. ", newBefore: "Hi. send this to Sasi", typed: " and copy Rishab")
        #expect(joined == "send this to Sasi and copy Rishab")
        // The second one fixed later: learned, and the earlier fix isn't learned twice.
        #expect(learn(joined!, "send this to Sasi and copy Rishabh") == ["Rishab→Rishabh"])
        #expect(CorrectionLearner.joinDictations(before: "Hi. ", newBefore: "Hello. send", typed: "x") == nil)
    }
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

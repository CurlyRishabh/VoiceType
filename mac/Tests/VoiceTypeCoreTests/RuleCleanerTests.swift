import Testing
@testable import VoiceTypeCore

// Generated from the Android RuleCleanerTest so both platforms test identical cases.
struct RuleCleanerTests {
    let c = RuleCleaner()

    @Test func removesUmAndUh() { #expect(c.removeFillers("So um I think uh we should go") == "So I think we should go") }
    @Test func removesStretchedFillers() { #expect(c.removeFillers("Ummm I think uhh so") == "I think so") }
    @Test func removesErErmHmm() { #expect(c.removeFillers("Well, er, erm, hmm, it works") == "Well, it works") }
    @Test func removesFillerAndItsCommas() { #expect(c.removeFillers("So, um, I think we should go.") == "So, I think we should go.") }
    @Test func removesLeadingFillerWithComma() { #expect(c.removeFillers("Um, I agree.") == "I agree.") }
    @Test func removesFillerBeforeFullStop() { #expect(c.removeFillers("I agree, uh.") == "I agree.") }
    @Test func doesNotTouchWordsContainingFillers() { #expect(c.removeFillers("The umbrella was under the hummingbird") == "The umbrella was under the hummingbird") }
    @Test func removesCommaBracketedYouKnow() { #expect(c.removeFillers("It's, you know, hard to say.") == "It's hard to say.") }
    @Test func removesClauseInitialYouKnow() { #expect(c.removeFillers("You know, it's late.") == "it's late.") }
    @Test func removesTrailingYouKnow() { #expect(c.removeFillers("It's late, you know.") == "It's late.") }
    @Test func keepsMeaningfulYouKnow() { #expect(c.removeFillers("Do you know him?") == "Do you know him?") }
    @Test func removesStandaloneLike() { #expect(c.removeFillers("I was, like, so tired.") == "I was so tired.") }
    @Test func removesClauseInitialLike() { #expect(c.removeFillers("Like, it was amazing.") == "it was amazing.") }
    @Test func keepsVerbLike() { #expect(c.removeFillers("I like pizza and it looks like rain.") == "I like pizza and it looks like rain.") }
    @Test func removesDoubledLike() { #expect(c.removeFillers("It was like like big.") == "It was big.") }
    @Test func removesHindiFillerMatlab() { #expect(c.removeFillers("matlab, main kal aaunga") == "main kal aaunga") }
    @Test func removesCommaBracketedMatlab() { #expect(c.removeFillers("woh, matlab, project late hai") == "woh project late hai") }
    @Test func keepsMeaningfulMatlab() { #expect(c.removeFillers("iska matlab kya hai") == "iska matlab kya hai") }
    @Test func removesDevanagariMatlab() { #expect(c.removeFillers("मतलब, मैं कल आऊँगा") == "मैं कल आऊँगा") }
    @Test func removesHaanToh() { #expect(c.removeFillers("haan toh kal milte hain") == "kal milte hain") }
    @Test func removesHaanTohDevanagari() { #expect(c.removeFillers("हाँ तो कल मिलते हैं") == "कल मिलते हैं") }
    @Test func removesHaanTohMidText() { #expect(c.removeFillers("Done. Haan toh, kal milte hain") == "Done. kal milte hain") }
    @Test func noWaitReplacesLastWord() { #expect(c.applySelfCorrections("Send it to John no wait Mary") == "Send it to Mary") }
    @Test func noWaitAlignsOnRepeatedWord() { #expect(c.applySelfCorrections("Let's meet at 5 no wait at 6") == "Let's meet at 6") }
    @Test func noWaitAlignsOnSecondWord() { #expect(c.applySelfCorrections("Meet on Tuesday at 5 no wait Wednesday at 6") == "Meet on Wednesday at 6") }
    @Test func noWaitWithAsrCommas() { #expect(c.applySelfCorrections("Call me at 5 pm, no, wait, 6 pm.") == "Call me at 6 pm.") }
    @Test func iMeanCorrection() { #expect(c.applySelfCorrections("Book it for Monday I mean Tuesday") == "Book it for Tuesday") }
    @Test func iMeanKeepsRestOfSentence() { #expect(c.applySelfCorrections("I'll bring cake I mean pie and juice") == "I'll bring pie and juice") }
    @Test func iMeanWithAlignment() { #expect(c.applySelfCorrections("Send the report to Rahul I mean the invoice to Rahul") == "Send the invoice to Rahul") }
    @Test func whatIMeanIsNotACorrection() { #expect(c.applySelfCorrections("That's what I mean") == "That's what I mean") }
    @Test func iMeanItIsNotACorrection() { #expect(c.applySelfCorrections("I said I mean it") == "I said I mean it") }
    @Test func clauseInitialIMeanWithCommaIsDropped() { #expect(c.applySelfCorrections("I mean, it's fine.") == "it's fine.") }
    @Test func clauseInitialIMeanWithoutCommaIsKept() { #expect(c.applySelfCorrections("I mean it's fine.") == "I mean it's fine.") }
    @Test func noWaitTimeIsNotACorrection() { #expect(c.applySelfCorrections("There's no wait time today") == "There's no wait time today") }
    @Test func hinglishNahiNahi() { #expect(c.applySelfCorrections("kal nahi nahi parson milte hain") == "parson milte hain") }
    @Test func hinglishNahiNahiAligns() { #expect(c.applySelfCorrections("main kal aaunga nahi nahi parson aaunga") == "main parson aaunga") }
    @Test func devanagariNahiNahi() { #expect(c.applySelfCorrections("कल नहीं नहीं परसों मिलते हैं") == "परसों मिलते हैं") }
    @Test func correctionStaysInsideItsSentence() { #expect(c.applySelfCorrections("I'm free. Meet at 5 no wait at 6.") == "I'm free. Meet at 6.") }
    @Test func correctionReplacingWholeClauseKeepsSentenceSpacing() { #expect(c.applySelfCorrections("Okay. John no wait Mary") == "Okay. Mary") }
    @Test func multipleCorrections() { #expect(c.applySelfCorrections("Meet at 5 no wait 6 I mean 7") == "Meet at 7") }
    @Test func actuallyNo() { #expect(c.applySelfCorrections("Order three actually no two pizzas") == "Order two pizzas") }
    @Test func newLine() { #expect(c.applySpokenCommands("Hi there new line How are you") == "Hi there\nHow are you") }
    @Test func newLineSwallowsAsrPunctuation() { #expect(c.applySpokenCommands("Hi there. New line. How are you?") == "Hi there.\nHow are you?") }
    @Test func newParagraph() { #expect(c.applySpokenCommands("First point new paragraph second point") == "First point\n\nsecond point") }
    @Test func hinglishNewLine() { #expect(c.applySpokenCommands("pehla nayi line doosra") == "pehla\ndoosra") }
    @Test func comma() { #expect(c.applySpokenCommands("Hello comma how are you") == "Hello, how are you") }
    @Test func commaReplacesAsrComma() { #expect(c.applySpokenCommands("Hello, comma, how are you") == "Hello, how are you") }
    @Test func fullStop() { #expect(c.applySpokenCommands("Done full stop Next") == "Done. Next") }
    @Test func periodAtEnd() { #expect(c.applySpokenCommands("That is all period") == "That is all.") }
    @Test func periodAsNounIsKept() { #expect(c.applySpokenCommands("The trial period ended") == "The trial period ended") }
    @Test func periodAfterArticleAtEndIsKept() { #expect(c.applySpokenCommands("It was a long period") == "It was a long period") }
    @Test func questionMark() { #expect(c.applySpokenCommands("Are you coming question mark") == "Are you coming?") }
    @Test func questionMarkReplacesAsrPeriod() { #expect(c.applySpokenCommands("Are you coming. Question mark.") == "Are you coming?") }
    @Test func exclamationMark() { #expect(c.applySpokenCommands("Great exclamation mark") == "Great!") }
    @Test func removesSpaceBeforePunctuation() { #expect(c.fixSpacingAndPunctuation("Hello , world !") == "Hello, world!") }
    @Test func addsSpaceAfterComma() { #expect(c.fixSpacingAndPunctuation("one,two") == "one, two") }
    @Test func keepsThousandsSeparatorAndDecimals() { #expect(c.fixSpacingAndPunctuation("It costs 1,000 or 3.5k") == "It costs 1,000 or 3.5k") }
    @Test func collapsesDoubleCommasAndCommaPeriod() { #expect(c.fixSpacingAndPunctuation("a,, b,.") == "a, b.") }
    @Test func keepsEllipsis() { #expect(c.fixSpacingAndPunctuation("Well... ok") == "Well... ok") }
    @Test func collapsesDoublePeriod() { #expect(c.fixSpacingAndPunctuation("End..") == "End.") }
    @Test func questionThenPeriod() { #expect(c.fixSpacingAndPunctuation("Really?.") == "Really?") }
    @Test func trimsAroundNewlines() { #expect(c.fixSpacingAndPunctuation("a \n b") == "a\nb") }
    @Test func limitsBlankLines() { #expect(c.fixSpacingAndPunctuation("a\n\n\n\nb") == "a\n\nb") }
    @Test func removesPunctuationAtLineStart() { #expect(c.fixSpacingAndPunctuation("a\n, b") == "a\nb") }
    @Test func collapsesSpaces() { #expect(c.fixSpacingAndPunctuation("a     b") == "a b") }
    @Test func capitalisesFirstLetter() { #expect(c.capitalize("hello there") == "Hello there") }
    @Test func capitalisesAfterSentenceEnd() { #expect(c.capitalize("one. two? three! four") == "One. Two? Three! Four") }
    @Test func capitalisesAfterNewline() { #expect(c.capitalize("one\ntwo") == "One\nTwo") }
    @Test func capitalisesStandaloneI() { #expect(c.capitalize("i think i'm right and i'll go") == "I think I'm right and I'll go") }
    @Test func doesNotCapitaliseIInsideWords() { #expect(c.capitalize("it is") == "It is") }
    @Test func keepsIe() { #expect(c.capitalize("fruit, i.e. apples") == "Fruit, i.e. apples") }
    @Test func midSentenceInsertKeepsLowercaseStart() { #expect(c.capitalize("and then. next", startsSentence: false) == "and then. Next") }
    @Test func capitalisationIgnoresDevanagari() { #expect(c.capitalize("नमस्ते. hello") == "नमस्ते. Hello") }
    @Test func addsFinalPeriod() { #expect(c.addFinalPunctuation("Hello") == "Hello.") }
    @Test func keepsExistingFinalPunctuation() { #expect(c.addFinalPunctuation("Hello?") == "Hello?") }
    @Test func addsDandaForDevanagari() { #expect(c.addFinalPunctuation("मैं ठीक हूँ") == "मैं ठीक हूँ।") }
    @Test func noFinalPunctuationAfterNewline() { #expect(c.addFinalPunctuation("List\n") == "List\n") }
    @Test func finalPeriodAfterDigit() { #expect(c.addFinalPunctuation("Meet at 6") == "Meet at 6.") }
    @Test func cleanOnlyFillers() { #expect(c.clean("um uh") == "") }
    @Test func normalizesWhitespace() { #expect(c.normalizeWhitespace("  a\t b \r\n c  ") == "a b\nc") }

    @Test func dictionaryAppliedAfterCapitalisation() {
        var o = CleanupOptions()
        o.dictionary = PersonalDictionary([.init("iphone", "iPhone"), .init("acme", "Acme")])
        #expect(c.clean("iphone sync works at acme", o) == "iPhone sync works at Acme.")
    }

    @Test func cleanEndToEnd() {
        #expect(c.clean("um so I think we should uh meet at 5 no wait 6 new line see you there exclamation mark")
            == "So I think we should meet at 6\nSee you there!")
    }

    @Test func cleanHinglish() {
        #expect(c.clean("haan toh main kal aaunga nahi nahi parson aaunga") == "Main parson aaunga.")
    }

    @Test func cleanRespectsDisabledRules() {
        var o = CleanupOptions()
        o.removeFillers = false; o.applySpokenCommands = false; o.applySelfCorrections = false
        o.autoCapitalize = false; o.addFinalPunctuation = false
        #expect(c.clean("um hello comma world", o) == "um hello comma world")
    }

    @Test func cleanEmpty() { #expect(c.clean("   ") == "") }

    @Test func correctionReachesBackOverAsrFullStop() {
        #expect(c.applySelfCorrections("So I think we should meet at 5. No wait. 6 tomorrow.") == "So I think we should meet at 6 tomorrow.")
    }
    @Test func iMeanDoesNotReachIntoPreviousSentence() {
        #expect(c.applySelfCorrections("It works. I mean, it's fine.") == "It works. it's fine.")
    }
    @Test func questionMarkAfterAsrQuestionMark() {
        #expect(c.applySpokenCommands("Can you send it? Question mark.") == "Can you send it?")
    }
}

struct TransliteratorTests {
    static let cases: [(String, String)] = [
        ("Hello, world 123", "Hello, world 123"),
        ("कमल", "kamal"),
        ("काम", "kaam"),
        ("घर", "ghar"),
        ("आप", "aap"),
        ("करना", "karna"),
        ("समझना", "samajhna"),
        ("मतलब", "matlab"),
        ("बोलता", "bolta"),
        ("अपना", "apna"),
        ("मिलते", "milte"),
        ("परसों", "parson"),
        ("न", "na"),
        ("मित्र", "mitra"),
        ("धन्यवाद", "dhanyavaad"),
        ("क्या", "kya"),
        ("नमस्ते", "namaste"),
        ("है", "hai"),
        ("हैं", "hain"),
        ("मैं", "main"),
        ("में", "mein"),
        ("नहीं", "nahin"),
        ("हूँ", "hoon"),
        ("हाँ", "haan"),
        ("था", "tha"),
        ("अभी", "abhi"),
        ("ठीक", "theek"),
        ("बहुत", "bahut"),
        ("कल", "kal"),
        ("आज", "aaj"),
        ("हिंदी", "hindi"),
        ("संभव", "sambhav"),
        ("ज़रूर", "zaroor"),
        ("ज़रूर", "zaroor"),
        ("फ़ोन", "fon"),
        ("मीटिंग", "meeting"),
        ("कल ५ बजे मीटिंग है।", "kal 5 baje meeting hai."),
        ("मुझे report send करनी है", "mujhe report send karni hai")
    ]

    @Test(arguments: cases) func toLatin(_ input: String, _ expected: String) {
        #expect(Transliterator.toLatin(input) == expected)
    }

    @Test func detectsDevanagari() {
        #expect(Transliterator.containsDevanagari("hello नमस्ते"))
        #expect(!Transliterator.containsDevanagari("hello"))
    }
}

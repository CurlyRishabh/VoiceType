package dev.offline.voicetype.cleanup

import org.junit.Assert.assertEquals
import org.junit.Test

class RuleCleanerTest {

    private val c = RuleCleaner()

    // ------------------------------------------------------------ fillers

    @Test fun removesUmAndUh() =
        assertEquals("So I think we should go", c.removeFillers("So um I think uh we should go"))

    @Test fun removesStretchedFillers() =
        assertEquals("I think so", c.removeFillers("Ummm I think uhh so"))

    @Test fun removesErErmHmm() =
        assertEquals("Well, it works", c.removeFillers("Well, er, erm, hmm, it works"))

    @Test fun removesFillerAndItsCommas() =
        assertEquals("So, I think we should go.", c.removeFillers("So, um, I think we should go."))

    @Test fun removesLeadingFillerWithComma() =
        assertEquals("I agree.", c.removeFillers("Um, I agree."))

    @Test fun removesFillerBeforeFullStop() =
        assertEquals("I agree.", c.removeFillers("I agree, uh."))

    @Test fun doesNotTouchWordsContainingFillers() =
        assertEquals("The umbrella was under the hummingbird", c.removeFillers("The umbrella was under the hummingbird"))

    @Test fun removesCommaBracketedYouKnow() =
        assertEquals("It's hard to say.", c.removeFillers("It's, you know, hard to say."))

    @Test fun removesClauseInitialYouKnow() =
        assertEquals("it's late.", c.removeFillers("You know, it's late."))

    @Test fun removesTrailingYouKnow() =
        assertEquals("It's late.", c.removeFillers("It's late, you know."))

    @Test fun keepsMeaningfulYouKnow() =
        assertEquals("Do you know him?", c.removeFillers("Do you know him?"))

    @Test fun removesStandaloneLike() =
        assertEquals("I was so tired.", c.removeFillers("I was, like, so tired."))

    @Test fun removesClauseInitialLike() =
        assertEquals("it was amazing.", c.removeFillers("Like, it was amazing."))

    @Test fun keepsVerbLike() =
        assertEquals("I like pizza and it looks like rain.", c.removeFillers("I like pizza and it looks like rain."))

    @Test fun removesDoubledLike() =
        assertEquals("It was big.", c.removeFillers("It was like like big."))

    @Test fun removesHindiFillerMatlab() =
        assertEquals("main kal aaunga", c.removeFillers("matlab, main kal aaunga"))

    @Test fun removesCommaBracketedMatlab() =
        assertEquals("woh project late hai", c.removeFillers("woh, matlab, project late hai"))

    @Test fun keepsMeaningfulMatlab() =
        assertEquals("iska matlab kya hai", c.removeFillers("iska matlab kya hai"))

    @Test fun removesDevanagariMatlab() =
        assertEquals("मैं कल आऊँगा", c.removeFillers("मतलब, मैं कल आऊँगा"))

    @Test fun removesHaanToh() =
        assertEquals("kal milte hain", c.removeFillers("haan toh kal milte hain"))

    @Test fun removesHaanTohDevanagari() =
        assertEquals("कल मिलते हैं", c.removeFillers("हाँ तो कल मिलते हैं"))

    @Test fun removesHaanTohMidText() =
        assertEquals("Done. kal milte hain", c.removeFillers("Done. Haan toh, kal milte hain"))

    // ------------------------------------------------------------ self-corrections

    @Test fun noWaitReplacesLastWord() =
        assertEquals("Send it to Mary", c.applySelfCorrections("Send it to John no wait Mary"))

    @Test fun noWaitAlignsOnRepeatedWord() =
        assertEquals("Let's meet at 6", c.applySelfCorrections("Let's meet at 5 no wait at 6"))

    @Test fun noWaitAlignsOnSecondWord() =
        assertEquals("Meet on Wednesday at 6", c.applySelfCorrections("Meet on Tuesday at 5 no wait Wednesday at 6"))

    @Test fun noWaitWithAsrCommas() =
        assertEquals("Call me at 6 pm.", c.applySelfCorrections("Call me at 5 pm, no, wait, 6 pm."))

    @Test fun iMeanCorrection() =
        assertEquals("Book it for Tuesday", c.applySelfCorrections("Book it for Monday I mean Tuesday"))

    @Test fun iMeanKeepsRestOfSentence() =
        assertEquals("I'll bring pie and juice", c.applySelfCorrections("I'll bring cake I mean pie and juice"))

    @Test fun iMeanWithAlignment() =
        assertEquals("Send the invoice to Rahul", c.applySelfCorrections("Send the report to Rahul I mean the invoice to Rahul"))

    @Test fun whatIMeanIsNotACorrection() =
        assertEquals("That's what I mean", c.applySelfCorrections("That's what I mean"))

    @Test fun iMeanItIsNotACorrection() =
        assertEquals("I said I mean it", c.applySelfCorrections("I said I mean it"))

    @Test fun clauseInitialIMeanWithCommaIsDropped() =
        assertEquals("it's fine.", c.applySelfCorrections("I mean, it's fine."))

    @Test fun clauseInitialIMeanWithoutCommaIsKept() =
        assertEquals("I mean it's fine.", c.applySelfCorrections("I mean it's fine."))

    @Test fun noWaitTimeIsNotACorrection() =
        assertEquals("There's no wait time today", c.applySelfCorrections("There's no wait time today"))

    @Test fun hinglishNahiNahi() =
        assertEquals("parson milte hain", c.applySelfCorrections("kal nahi nahi parson milte hain"))

    @Test fun hinglishNahiNahiAligns() =
        assertEquals("main parson aaunga", c.applySelfCorrections("main kal aaunga nahi nahi parson aaunga"))

    @Test fun devanagariNahiNahi() =
        assertEquals("परसों मिलते हैं", c.applySelfCorrections("कल नहीं नहीं परसों मिलते हैं"))

    @Test fun correctionStaysInsideItsSentence() =
        assertEquals("I'm free. Meet at 6.", c.applySelfCorrections("I'm free. Meet at 5 no wait at 6."))

    @Test fun correctionReplacingWholeClauseKeepsSentenceSpacing() =
        assertEquals("Okay. Mary", c.applySelfCorrections("Okay. John no wait Mary"))

    @Test fun correctionReachesBackOverAsrFullStop() =
        assertEquals("So I think we should meet at 6 tomorrow.", c.applySelfCorrections("So I think we should meet at 5. No wait. 6 tomorrow."))

    @Test fun iMeanDoesNotReachIntoPreviousSentence() =
        assertEquals("It works. it's fine.", c.applySelfCorrections("It works. I mean, it's fine."))

    @Test fun multipleCorrections() =
        assertEquals("Meet at 7", c.applySelfCorrections("Meet at 5 no wait 6 I mean 7"))

    @Test fun actuallyNo() =
        assertEquals("Order two pizzas", c.applySelfCorrections("Order three actually no two pizzas"))

    // ------------------------------------------------------------ spoken commands

    @Test fun newLine() =
        assertEquals("Hi there\nHow are you", c.applySpokenCommands("Hi there new line How are you"))

    @Test fun newLineSwallowsAsrPunctuation() =
        assertEquals("Hi there.\nHow are you?", c.applySpokenCommands("Hi there. New line. How are you?"))

    @Test fun newParagraph() =
        assertEquals("First point\n\nsecond point", c.applySpokenCommands("First point new paragraph second point"))

    @Test fun hinglishNewLine() =
        assertEquals("pehla\ndoosra", c.applySpokenCommands("pehla nayi line doosra"))

    @Test fun comma() =
        assertEquals("Hello, how are you", c.applySpokenCommands("Hello comma how are you"))

    @Test fun commaReplacesAsrComma() =
        assertEquals("Hello, how are you", c.applySpokenCommands("Hello, comma, how are you"))

    @Test fun fullStop() =
        assertEquals("Done. Next", c.applySpokenCommands("Done full stop Next"))

    @Test fun periodAtEnd() =
        assertEquals("That is all.", c.applySpokenCommands("That is all period"))

    @Test fun periodAsNounIsKept() =
        assertEquals("The trial period ended", c.applySpokenCommands("The trial period ended"))

    @Test fun periodAfterArticleAtEndIsKept() =
        assertEquals("It was a long period", c.applySpokenCommands("It was a long period"))

    @Test fun questionMark() =
        assertEquals("Are you coming?", c.applySpokenCommands("Are you coming question mark"))

    @Test fun questionMarkReplacesAsrPeriod() =
        assertEquals("Are you coming?", c.applySpokenCommands("Are you coming. Question mark."))

    @Test fun questionMarkAfterAsrQuestionMark() =
        assertEquals("Can you send it?", c.applySpokenCommands("Can you send it? Question mark."))

    @Test fun exclamationMark() =
        assertEquals("Great!", c.applySpokenCommands("Great exclamation mark"))

    // ------------------------------------------------------------ spacing & punctuation

    @Test fun removesSpaceBeforePunctuation() =
        assertEquals("Hello, world!", c.fixSpacingAndPunctuation("Hello , world !"))

    @Test fun addsSpaceAfterComma() =
        assertEquals("one, two", c.fixSpacingAndPunctuation("one,two"))

    @Test fun keepsThousandsSeparatorAndDecimals() =
        assertEquals("It costs 1,000 or 3.5k", c.fixSpacingAndPunctuation("It costs 1,000 or 3.5k"))

    @Test fun collapsesDoubleCommasAndCommaPeriod() =
        assertEquals("a, b.", c.fixSpacingAndPunctuation("a,, b,."))

    @Test fun keepsEllipsis() =
        assertEquals("Well... ok", c.fixSpacingAndPunctuation("Well... ok"))

    @Test fun collapsesDoublePeriod() =
        assertEquals("End.", c.fixSpacingAndPunctuation("End.."))

    @Test fun questionThenPeriod() =
        assertEquals("Really?", c.fixSpacingAndPunctuation("Really?."))

    @Test fun trimsAroundNewlines() =
        assertEquals("a\nb", c.fixSpacingAndPunctuation("a \n b"))

    @Test fun limitsBlankLines() =
        assertEquals("a\n\nb", c.fixSpacingAndPunctuation("a\n\n\n\nb"))

    @Test fun removesPunctuationAtLineStart() =
        assertEquals("a\nb", c.fixSpacingAndPunctuation("a\n, b"))

    @Test fun collapsesSpaces() =
        assertEquals("a b", c.fixSpacingAndPunctuation("a     b"))

    // ------------------------------------------------------------ capitalisation

    @Test fun capitalisesFirstLetter() = assertEquals("Hello there", c.capitalize("hello there"))

    @Test fun capitalisesAfterSentenceEnd() = assertEquals("One. Two? Three! Four", c.capitalize("one. two? three! four"))

    @Test fun capitalisesAfterNewline() = assertEquals("One\nTwo", c.capitalize("one\ntwo"))

    @Test fun capitalisesStandaloneI() = assertEquals("I think I'm right and I'll go", c.capitalize("i think i'm right and i'll go"))

    @Test fun doesNotCapitaliseIInsideWords() = assertEquals("It is", c.capitalize("it is"))

    @Test fun keepsIe() = assertEquals("Fruit, i.e. apples", c.capitalize("fruit, i.e. apples"))

    @Test fun midSentenceInsertKeepsLowercaseStart() =
        assertEquals("and then. Next", c.capitalize("and then. next", startsSentence = false))

    @Test fun capitalisationIgnoresDevanagari() = assertEquals("नमस्ते. Hello", c.capitalize("नमस्ते. hello"))

    // ------------------------------------------------------------ final punctuation

    @Test fun addsFinalPeriod() = assertEquals("Hello.", c.addFinalPunctuation("Hello"))

    @Test fun keepsExistingFinalPunctuation() = assertEquals("Hello?", c.addFinalPunctuation("Hello?"))

    @Test fun addsDandaForDevanagari() = assertEquals("मैं ठीक हूँ।", c.addFinalPunctuation("मैं ठीक हूँ"))

    @Test fun noFinalPunctuationAfterNewline() = assertEquals("List\n", c.addFinalPunctuation("List\n"))

    @Test fun finalPeriodAfterDigit() = assertEquals("Meet at 6.", c.addFinalPunctuation("Meet at 6"))

    // ------------------------------------------------------------ dictionary inside clean()

    @Test fun dictionaryAppliedAfterCapitalisation() {
        val dict = PersonalDictionary(listOf(PersonalDictionary.Entry("iphone", "iPhone"), PersonalDictionary.Entry("acme", "Acme")))
        assertEquals("iPhone sync works at Acme.", c.clean("iphone sync works at acme", CleanupOptions(dictionary = dict)))
    }

    // ------------------------------------------------------------ full pipeline

    @Test fun cleanEndToEnd() = assertEquals(
        "So I think we should meet at 6\nSee you there!",
        c.clean("um so I think we should uh meet at 5 no wait 6 new line see you there exclamation mark"),
    )

    @Test fun cleanHinglish() = assertEquals(
        "Main parson aaunga.",
        c.clean("haan toh main kal aaunga nahi nahi parson aaunga"),
    )

    @Test fun cleanRespectsDisabledRules() = assertEquals(
        "um hello comma world",
        c.clean(
            "um hello comma world",
            CleanupOptions(
                removeFillers = false, applySpokenCommands = false, applySelfCorrections = false,
                autoCapitalize = false, addFinalPunctuation = false,
            ),
        ),
    )

    @Test fun cleanEmpty() = assertEquals("", c.clean("   "))

    @Test fun cleanOnlyFillers() = assertEquals("", c.clean("um uh"))

    @Test fun normalizesWhitespace() = assertEquals("a b\nc", c.normalizeWhitespace("  a\t b \r\n c  "))
}

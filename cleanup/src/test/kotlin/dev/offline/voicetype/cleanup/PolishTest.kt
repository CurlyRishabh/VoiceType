package dev.offline.voicetype.cleanup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PolishPromptTest {

    @Test fun promptContainsRulesStyleAndDelimitedText() {
        val r = PolishPrompt.build("hello there", PolishStyle.PROFESSIONAL, OutputScript.LATIN)
        assertTrue(r.systemInstruction.contains("Never translate"))
        assertTrue(r.systemInstruction.contains("Never add information"))
        assertTrue(r.systemInstruction.contains("professional email"))
        assertEquals("<<<\nhello there\n>>>", r.userMessage)
    }

    @Test fun notesStyleAsksForBullets() =
        assertTrue(PolishPrompt.build("a", PolishStyle.NOTES, OutputScript.LATIN).systemInstruction.contains("bullet"))

    @Test fun casualStyle() =
        assertTrue(PolishPrompt.build("a", PolishStyle.CASUAL, OutputScript.LATIN).systemInstruction.contains("casual"))

    @Test fun hinglishLatinGetsScriptInstruction() =
        assertTrue(
            PolishPrompt.build("kal meeting hai, main nahi aa paunga", PolishStyle.CASUAL, OutputScript.LATIN)
                .systemInstruction.contains("Latin script"),
        )

    @Test fun devanagariGetsScriptInstruction() =
        assertTrue(PolishPrompt.build("कल मीटिंग है", PolishStyle.CASUAL, OutputScript.DEVANAGARI).systemInstruction.contains("Devanagari"))

    @Test fun tokenBudgetIsBounded() {
        assertEquals(48, PolishPrompt.build("", PolishStyle.CASUAL, OutputScript.LATIN).maxOutputTokens)
        assertEquals(512, PolishPrompt.build("x".repeat(5000), PolishStyle.CASUAL, OutputScript.LATIN).maxOutputTokens)
    }

    @Test fun extractStripsWrappers() {
        assertEquals("Hello there.", PolishPrompt.extract("Here is the cleaned text:\nHello there."))
        assertEquals("Hello there.", PolishPrompt.extract("<<<\nHello there.\n>>>"))
        assertEquals("Hello there.", PolishPrompt.extract("```\nHello there.\n```"))
        assertEquals("Hello there.", PolishPrompt.extract("\"Hello there.\""))
        assertEquals("Hello there.", PolishPrompt.extract("Sure! Here's the corrected text: Hello there."))
    }

    @Test fun extractKeepsNormalText() = assertEquals("Line one\nLine two", PolishPrompt.extract("  Line one\nLine two  "))
}

class PolishGuardTest {

    private fun ok(input: String, output: String, style: PolishStyle = PolishStyle.CASUAL) =
        PolishGuard.check(input, output, style) == PolishGuard.Verdict.Accept

    @Test fun acceptsGrammarFix() = assertTrue(ok("me and him goes to the store tomorrow", "He and I are going to the store tomorrow."))

    @Test fun acceptsSpellingFixes() = assertTrue(ok("kal miting hai office mein", "Kal meeting hai office mein."))

    @Test fun rejectsEmpty() = assertFalse(ok("hello", "  "))

    @Test fun rejectsAnsweringQuestion() =
        assertFalse(ok("what is the capital of France", "The capital of France is Paris, a city known for the Eiffel Tower and its museums and long history."))

    @Test fun rejectsAssistantTone() = assertFalse(ok("send the file", "Sure! I have sent the file."))

    @Test fun rejectsTranslationToEnglish() = assertFalse(ok("मैं कल ऑफिस आऊँगा", "I will come to the office tomorrow."))

    @Test fun rejectsTranslationToHindi() = assertFalse(ok("I will come to the office tomorrow", "मैं कल ऑफिस आऊँगा।"))

    @Test fun rejectsDroppedContent() = assertFalse(ok("please remember to send the quarterly report to the whole finance team", "Send it."))

    @Test fun rejectsInventedContent() =
        assertFalse(ok("thanks for the update", "Thanks for the update! I really appreciate your hard work and dedication on this project."))

    @Test fun notesMayAddBulletMarkers() =
        assertTrue(ok("buy milk and eggs and call mom", "- Buy milk and eggs\n- Call mom", PolishStyle.NOTES))
}

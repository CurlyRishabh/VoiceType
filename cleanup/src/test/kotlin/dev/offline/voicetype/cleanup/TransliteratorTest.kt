package dev.offline.voicetype.cleanup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransliteratorTest {

    private fun t(s: String) = Transliterator.toLatin(s)

    @Test fun latinPassesThrough() = assertEquals("Hello, world 123", t("Hello, world 123"))

    @Test fun detectsDevanagari() {
        assertTrue(Transliterator.containsDevanagari("hello नमस्ते"))
        assertFalse(Transliterator.containsDevanagari("hello"))
    }

    @Test fun finalSchwaDeletion() {
        assertEquals("kamal", t("कमल"))
        assertEquals("kaam", t("काम"))
        assertEquals("ghar", t("घर"))
        assertEquals("aap", t("आप"))
    }

    @Test fun medialSchwaDeletion() {
        assertEquals("karna", t("करना"))
        assertEquals("samajhna", t("समझना"))
        assertEquals("matlab", t("मतलब"))
        assertEquals("bolta", t("बोलता"))
        assertEquals("apna", t("अपना"))
        assertEquals("milte", t("मिलते"))
        assertEquals("parson", t("परसों"))
    }

    @Test fun keepsSchwaInSingleSyllableAndConjunctEndings() {
        assertEquals("na", t("न"))
        assertEquals("mitra", t("मित्र"))
        assertEquals("dhanyavaad", t("धन्यवाद"))
    }

    @Test fun conjuncts() {
        assertEquals("kya", t("क्या"))
        assertEquals("namaste", t("नमस्ते"))
    }

    @Test fun commonHinglishWords() {
        assertEquals("hai", t("है"))
        assertEquals("hain", t("हैं"))
        assertEquals("main", t("मैं"))
        assertEquals("mein", t("में"))
        assertEquals("nahin", t("नहीं"))
        assertEquals("hoon", t("हूँ"))
        assertEquals("haan", t("हाँ"))
        assertEquals("tha", t("था"))
        assertEquals("abhi", t("अभी"))
        assertEquals("theek", t("ठीक"))
        assertEquals("bahut", t("बहुत"))
        assertEquals("kal", t("कल"))
        assertEquals("aaj", t("आज"))
    }

    @Test fun anusvaraBecomesMBeforeLabials() {
        assertEquals("hindi", t("हिंदी"))
        assertEquals("sambhav", t("संभव"))
    }

    @Test fun nuktaPrecomposedAndDecomposed() {
        assertEquals("zaroor", t("ज़रूर"))       // precomposed ज़
        assertEquals("zaroor", t("ज़रूर"))      // ज + nukta
        assertEquals("fon", t("फ़ोन"))           // फ़ोन
    }

    @Test fun englishLoanWords() = assertEquals("meeting", t("मीटिंग"))

    @Test fun sentenceWithPunctuationAndDigits() =
        assertEquals("kal 5 baje meeting hai.", t("कल ५ बजे मीटिंग है।"))

    @Test fun mixedScriptKeepsLatinWords() =
        assertEquals("mujhe report send karni hai", t("मुझे report send करनी है"))
}

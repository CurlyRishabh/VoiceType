package dev.offline.voicetype.cleanup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonalDictionaryTest {

    private fun dict(vararg pairs: Pair<String, String>) =
        PersonalDictionary(pairs.map { PersonalDictionary.Entry(it.first, it.second) })

    @Test fun replacesCaseInsensitively() =
        assertEquals("I work at Acme and Acme is great", dict("acme" to "Acme").apply("I work at acme and ACME is great"))

    @Test fun wholeWordsOnly() =
        assertEquals("acmefied stays", dict("acme" to "Acme").apply("acmefied stays"))

    @Test fun multiWordPhraseWithFlexibleSpacing() =
        assertEquals("Ask AcmeHQ today", dict("acme h q" to "AcmeHQ").apply("Ask acme  h q today"))

    @Test fun longerPhraseWins() =
        assertEquals("NYT and New York", dict("new york" to "New York", "new york times" to "NYT").apply("new york times and new york"))

    @Test fun replacementIsLiteral() =
        assertEquals("cost \$5", dict("five bucks" to "\$5").apply("cost five bucks"))

    @Test fun worksWithDevanagari() =
        assertEquals("Acme में", dict("एक्मे" to "Acme").apply("एक्मे में"))

    @Test fun serializeRoundTrip() {
        val d = dict("acme" to "Acme", "gpt" to "GPT")
        assertEquals(d.entries, PersonalDictionary.parse(d.serialize()).entries)
    }

    @Test fun parseIgnoresJunk() {
        val d = PersonalDictionary.parse("a\tb\nbroken line\n\n c \t d ")
        assertEquals(listOf(PersonalDictionary.Entry("a", "b"), PersonalDictionary.Entry("c", "d")), d.entries)
    }

    @Test fun plusReplacesExistingEntry() {
        val d = dict("acme" to "Acme").plus(PersonalDictionary.Entry("ACME", "ACME Inc"))
        assertEquals(1, d.entries.size)
        assertEquals("ACME Inc", d.entries.single().to)
    }

    @Test fun minusRemovesEntry() = assertTrue(dict("a" to "b").minus("A").isEmpty())

    @Test fun dropsBlankEntries() = assertTrue(dict(" " to "x", "y" to "").isEmpty())
}

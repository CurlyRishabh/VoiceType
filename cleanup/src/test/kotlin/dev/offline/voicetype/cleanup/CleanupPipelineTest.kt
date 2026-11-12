package dev.offline.voicetype.cleanup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CleanupPipelineTest {

    private open class FakePolisher(
        override var isReady: Boolean = true,
        val reply: (PolishRequest) -> String,
    ) : Polisher {
        var warmUps = 0
        var cancels = 0
        var lastRequest: PolishRequest? = null
        override fun warmUp() { warmUps++ }
        override fun polish(request: PolishRequest): String { lastRequest = request; return reply(request) }
        override fun cancel() { cancels++ }
    }

    private val polishOn = CleanupSettings(polishEnabled = true)

    @Test fun stage1OnlyWhenPolishDisabled() {
        val p = FakePolisher { "SHOULD NOT BE USED" }
        val r = CleanupPipeline(p).process("um hello world", CleanupSettings(polishEnabled = false))
        assertEquals("Hello world.", r.text)
        assertFalse(r.polished)
        assertEquals(null, p.lastRequest)
    }

    @Test fun usesPolishedText() {
        val p = FakePolisher { "Hello, world." }
        val r = CleanupPipeline(p).process("um hello world", polishOn)
        assertEquals("Hello world.", r.stage1)
        assertEquals("Hello, world.", r.text)
        assertTrue(r.polished)
        assertTrue(p.lastRequest!!.userMessage.contains("Hello world."))
    }

    @Test fun fallsBackAndCancelsOnTimeout() {
        val release = CountDownLatch(1)
        val p = FakePolisher { release.await(10, TimeUnit.SECONDS); "late" }
        val started = System.nanoTime()
        val r = CleanupPipeline(p, timeoutMillis = 200).process("hello world", polishOn)
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        release.countDown()
        assertEquals("Hello world.", r.text)
        assertFalse(r.polished)
        assertEquals(1, p.cancels)
        assertTrue("took $elapsedMs ms", elapsedMs < 1_500)
        assertTrue(r.fallbackReason!!.contains("timed out"))
    }

    @Test fun fallsBackOnException() {
        val r = CleanupPipeline(FakePolisher { error("boom") }).process("hello world", polishOn)
        assertEquals("Hello world.", r.text)
        assertTrue(r.fallbackReason!!.contains("boom"))
    }

    @Test fun fallsBackWhenModelNotReadyAndStartsWarmUp() {
        val p = FakePolisher(isReady = false) { "x" }
        val r = CleanupPipeline(p).process("hello world", polishOn)
        assertEquals("Hello world.", r.text)
        assertEquals(1, p.warmUps)
        assertNotNull(r.fallbackReason)
    }

    @Test fun rejectsTranslation() {
        val r = CleanupPipeline(FakePolisher { "मैं कल आऊँगा।" }).process("main kal aaunga", polishOn)
        assertEquals("Main kal aaunga.", r.text)
        assertTrue(r.fallbackReason!!.contains("rejected"))
    }

    @Test fun dictionaryWinsOverModel() {
        val dict = PersonalDictionary(listOf(PersonalDictionary.Entry("acme", "Acme")))
        val settings = polishOn.copy(options = CleanupOptions(dictionary = dict))
        val r = CleanupPipeline(FakePolisher { "I work at Acm and acme." }).process("i work at acme", settings)
        assertEquals("I work at Acm and Acme.", r.text)
    }

    @Test fun transliteratesBeforeCleaningWhenLatinRequested() {
        val r = CleanupPipeline(null).process("कल मीटिंग है", CleanupSettings(script = OutputScript.LATIN))
        assertEquals("Kal meeting hai.", r.text)
    }

    @Test fun keepsDevanagariWhenRequested() {
        val r = CleanupPipeline(null).process("कल मीटिंग है", CleanupSettings(script = OutputScript.DEVANAGARI))
        assertEquals("कल मीटिंग है।", r.text)
    }

    @Test fun midSentenceInsertKeepsLowercaseAfterPolish() {
        val settings = polishOn.copy(options = CleanupOptions(startsSentence = false))
        val r = CleanupPipeline(FakePolisher { "And then we left." }).process("and then we left", settings)
        assertEquals("and then we left.", r.text)
    }

    @Test fun blankInputSkipsPolish() {
        val p = FakePolisher { "x" }
        val r = CleanupPipeline(p).process("um", polishOn)
        assertEquals("", r.text)
        assertEquals(null, p.lastRequest)
    }
}

class TextJoinTest {

    @Test fun startsSentence() {
        assertTrue(TextJoin.startsSentence(null))
        assertTrue(TextJoin.startsSentence(""))
        assertTrue(TextJoin.startsSentence("Done. "))
        assertTrue(TextJoin.startsSentence("Line\n"))
        assertFalse(TextJoin.startsSentence("I went to"))
    }

    @Test fun endsSentence() {
        assertTrue(TextJoin.endsSentence(""))
        assertTrue(TextJoin.endsSentence("  \nnext line"))
        assertFalse(TextJoin.endsSentence(" and more"))
    }

    @Test fun padsBetweenWords() {
        assertEquals(" world", TextJoin.pad("world", "hello", null))
        assertEquals("world", TextJoin.pad("world", "hello ", null))
        assertEquals("big ", TextJoin.pad("big", "a ", "house"))
        assertEquals(" big", TextJoin.pad("big", "a", ", ok"))
    }

    @Test fun mergeInsertsAtCursorAndReplacesSelection() {
        assertEquals(TextJoin.Merged("Hello big world", 10), TextJoin.merge("Hello world", 6, 6, "big"))
        assertEquals(TextJoin.Merged("Hello there", 11), TextJoin.merge("Hello world", 6, 11, "there"))
        assertEquals(TextJoin.Merged("Hello world", 11), TextJoin.merge("Hello", -1, -1, "world"))
        assertEquals(TextJoin.Merged("Hi", 2), TextJoin.merge("", 0, 0, "Hi"))
    }

    @Test fun mergeHandlesReversedSelection() =
        assertEquals(TextJoin.Merged("Hello there", 11), TextJoin.merge("Hello world", 11, 6, "there"))
}

package dev.offline.voicetype.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AudioChunkerTest {

    private val s = SAMPLE_RATE

    @Test fun noVadSplitsWholeAudio() {
        val plan = AudioChunker.plan(s * 60, segments = null)
        assertEquals(3, plan.size)
        assertTrue(plan.all { it.length <= AudioChunker.MAX_CHUNK_SAMPLES })
        assertEquals(s * 60, plan.sumOf { it.length })
    }

    @Test fun noSpeechMeansNoChunks() = assertTrue(AudioChunker.plan(s * 5, emptyList()).isEmpty())

    @Test fun padsAndClampsSegment() {
        val plan = AudioChunker.plan(s * 2, listOf(Segment(100, s.toLong())))
        assertEquals(listOf(AudioChunker.Range(0, 100 + s + AudioChunker.PAD_SAMPLES)), plan)
    }

    @Test fun mergesNearbySegments() {
        val plan = AudioChunker.plan(s * 10, listOf(Segment(s * 1L, s * 1L), Segment(s * 3L, s * 1L)))
        assertEquals(1, plan.size)
    }

    @Test fun keepsDistantSegmentsApart() {
        val plan = AudioChunker.plan(s * 20, listOf(Segment(s * 1L, s * 1L), Segment(s * 10L, s * 1L)))
        assertEquals(2, plan.size)
    }

    @Test fun neverExceedsMaxChunk() {
        val segs = (0 until 20).map { Segment(it * s * 2L, s * 2L - 100) }
        val plan = AudioChunker.plan(s * 45, segs)
        assertTrue(plan.all { it.length <= AudioChunker.MAX_CHUNK_SAMPLES })
    }
}

class HallucinationFilterTest {

    @Test fun removesTags() = assertEquals("Hello there", HallucinationFilter.clean("[Music] Hello (upbeat music) there ♪", 5_000))

    @Test fun dropsImplausiblePhraseOnShortSpeech() = assertEquals("", HallucinationFilter.clean("Thanks for watching!", 900))

    @Test fun dropsThankYouWithoutSpeech() = assertEquals("", HallucinationFilter.clean("Thank you.", 100))

    @Test fun keepsShortRealThankYou() = assertEquals("Thank you.", HallucinationFilter.clean("Thank you.", 700))

    @Test fun keepsNormalShortText() = assertEquals("Yes.", HallucinationFilter.clean("Yes.", 400))

    @Test fun collapsesDecoderLoops() {
        assertEquals("अप आप", HallucinationFilter.collapseRepeats("अप आप आप आप आप आप आप"))
        assertEquals("go to the end", HallucinationFilter.collapseRepeats("go to the go to the go to the go to the end"))
        assertEquals("very very good", HallucinationFilter.collapseRepeats("very very good"))
    }
}

class WhisperBudgetTest {
    private val s = SAMPLE_RATE

    @Test fun paddingOnlyForWhisperNonEnglish() {
        assertTrue(!WhisperBudget.needsPadding(true, "en"))
        assertTrue(WhisperBudget.needsPadding(true, "hi") && WhisperBudget.needsPadding(true, ""))
        assertTrue(!WhisperBudget.needsPadding(false, "hi"))
    }

    @Test fun padsToBudgetWithinWindow() {
        assertEquals(7 * s, WhisperBudget.paddedLength(2 * s))
        assertEquals(29 * s, WhisperBudget.paddedLength(20 * s))
    }

    @Test fun hindiChunksAreShortAndPadded() {
        val pcm = ShortArray(20 * s) { 1000 }
        val hi = AudioChunker.chunks(pcm, null, whisper = true, language = "hi")
        assertEquals(3, hi.size)
        assertTrue(hi.all { it.size <= 29 * s })
        assertEquals(0f, hi[0].last())
        assertEquals(1, AudioChunker.chunks(pcm, null, whisper = false, language = "en").size)
    }
}

class ModelLayoutTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun dir(vararg names: String) = tmp.newFolder().also { d -> names.forEach { java.io.File(d, it).writeText("x") } }

    @Test fun findsMoonshineV1PreferringInt8() {
        val d = dir("preprocess.onnx", "encode.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt")
        val f = ModelLayout.findMoonshine(d) as SpeechModelFiles.MoonshineV1
        assertEquals("encode.int8.onnx", f.encoder.name)
    }

    @Test fun findsMoonshineV2() {
        val d = dir("encoder_model.ort", "decoder_model_merged.ort", "tokens.txt")
        assertTrue(ModelLayout.findMoonshine(d) is SpeechModelFiles.MoonshineV2)
    }

    @Test fun moonshineNeedsTokens() = assertNull(ModelLayout.findMoonshine(dir("encoder_model.ort", "decoder_model_merged.ort")))

    @Test fun findsWhisperInt8() {
        val d = dir("small-encoder.onnx", "small-encoder.int8.onnx", "small-decoder.int8.onnx", "small-tokens.txt")
        val f = ModelLayout.findWhisper(d)
        assertNotNull(f)
        assertEquals("small-encoder.int8.onnx", f!!.encoder.name)
        assertEquals("small-tokens.txt", f.tokens.name)
    }

    @Test fun findsVadAndLlm() {
        assertNotNull(ModelLayout.findVad(dir("silero_vad.onnx")))
        assertNotNull(ModelLayout.findLlm(dir("gemma3-1b-it-int4.litertlm")))
    }

    @Test fun acceptsOnlyRelevantFiles() {
        assertTrue(ModelLayout.accepts(ModelSlot.LLM, "model.litertlm"))
        assertTrue(!ModelLayout.accepts(ModelSlot.LLM, "model.onnx"))
        assertTrue(ModelLayout.accepts(ModelSlot.WHISPER, "small-tokens.txt"))
        assertTrue(!ModelLayout.accepts(ModelSlot.VAD, "readme.md"))
    }
}

class WavWriterTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun roundTrip() {
        val pcm = ShortArray(1000) { (it * 31).toShort() }
        val f = java.io.File(tmp.root, "a.wav")
        WavWriter.write(f, pcm)
        assertEquals(44 + 2000L, f.length())
        assertTrue(pcm.contentEquals(WavWriter.read(f)))
    }
}

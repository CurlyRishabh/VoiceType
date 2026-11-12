package dev.offline.voicetype.engine

/**
 * Turns VAD speech segments into decode chunks: nearby segments are merged (better context for
 * the model, fewer decode calls), silence between distant segments is skipped, and every chunk
 * stays under [maxChunkSamples] so Whisper's 30 s window is never exceeded.
 */
object AudioChunker {

    data class Range(val start: Int, val end: Int) {
        val length get() = end - start
    }

    const val PAD_SAMPLES = SAMPLE_RATE / 4             // 250 ms context on each side
    const val MAX_CHUNK_SAMPLES = SAMPLE_RATE * 25       // 25 s
    private const val MAX_MERGE_GAP = SAMPLE_RATE * 3    // merge segments separated by < 3 s

    fun plan(
        totalSamples: Int,
        segments: List<Segment>?,
        maxChunkSamples: Int = MAX_CHUNK_SAMPLES,
    ): List<Range> {
        if (totalSamples <= 0) return emptyList()
        // No VAD available: decode everything in fixed windows.
        if (segments == null) return split(Range(0, totalSamples), maxChunkSamples)

        val padded = segments
            .sortedBy { it.start }
            .map {
                Range(
                    (it.start - PAD_SAMPLES).coerceAtLeast(0).toInt(),
                    (it.end + PAD_SAMPLES).coerceAtMost(totalSamples.toLong()).toInt(),
                )
            }
            .filter { it.length > 0 }

        val merged = ArrayList<Range>()
        for (r in padded) {
            val last = merged.lastOrNull()
            if (last != null && r.start - last.end < MAX_MERGE_GAP && r.end - last.start <= maxChunkSamples) {
                merged[merged.size - 1] = Range(last.start, maxOf(last.end, r.end))
            } else {
                merged += r
            }
        }
        return merged.flatMap { split(it, maxChunkSamples) }
    }

    /** Decode-ready float chunks; Whisper Hindi/auto chunks are short and silence-padded (see [WhisperBudget]). */
    fun chunks(pcm: ShortArray, segments: List<Segment>?, whisper: Boolean, language: String): List<FloatArray> {
        val padding = WhisperBudget.needsPadding(whisper, language)
        val max = if (padding) WhisperBudget.MAX_CHUNK_SAMPLES else MAX_CHUNK_SAMPLES
        return plan(pcm.size, segments, max).map { r ->
            val length = if (padding) WhisperBudget.paddedLength(r.length) else r.length
            FloatArray(length) { i -> if (i < r.length) pcm[r.start + i] / 32768f else 0f }
        }
    }

    private fun split(r: Range, max: Int): List<Range> {
        if (r.length <= max) return listOf(r)
        val out = ArrayList<Range>()
        var s = r.start
        while (s < r.end) {
            val e = minOf(s + max, r.end)
            out += Range(s, e)
            s = e
        }
        return out
    }
}

/**
 * sherpa-onnx's Whisper decoder allows at most 6 output tokens per second of input audio
 * ("assume at most 6 tokens per second"). Devanagari needs ~3x that, so Hindi transcripts were
 * cut off mid-sentence. Fix: keep Hindi/auto chunks <= 8 s and append silence (zeros — exactly what
 * Whisper itself pads with) so the budget covers ~21 tokens per second of real speech.
 */
object WhisperBudget {
    private const val TOKENS_PER_SECOND_NEEDED = 21.0
    private const val SHERPA_TOKENS_PER_SECOND = 6.0
    private const val MAX_PADDED_SECONDS = 29.0
    const val MAX_CHUNK_SAMPLES = SAMPLE_RATE * 8

    fun needsPadding(whisper: Boolean, language: String) = whisper && language != "en"

    fun paddedLength(count: Int): Int {
        val wanted = count * TOKENS_PER_SECOND_NEEDED / SHERPA_TOKENS_PER_SECOND
        return maxOf(count, minOf(wanted, MAX_PADDED_SECONDS * SAMPLE_RATE).toInt())
    }
}

package dev.offline.voicetype.engine

/**
 * Whisper famously "hears" phrases like "Thank you." or "[Music]" in near-silence. Non-speech tags
 * are always removed; stock phrases are dropped only when the detected speech was very short.
 */
object HallucinationFilter {

    private val tags = Regex("\\[[^\\]]*]|\\((?:[^)]*(?:music|applause|laughter|silence|noise|blank)[^)]*)\\)|[♪♫]+", RegexOption.IGNORE_CASE)

    // Phrases nobody dictates in under a second but Whisper invents from noise.
    private val implausible = setOf(
        "thanks for watching", "thank you for watching", "please subscribe", "subscribe",
        "like and subscribe", "you",
    )

    // Real words people do say; dropped only when the VAD heard (almost) no speech at all.
    private val needsRealSpeech = setOf("thank you", "thanks", "thank you very much", "धन्यवाद", "शुक्रिया")

    /** Collapses decoder loops: the same word or 2-3 word phrase repeated 4+ times in a row. */
    fun collapseRepeats(text: String): String {
        var t = text
        for (n in listOf(3, 2, 1)) {
            val unit = List(n) { "\\S+" }.joinToString("\\s+")
            t = Regex("(?<!\\S)($unit)(?:\\s+\\1){3,}(?!\\S)").replace(t, "$1")
        }
        return t
    }

    fun clean(text: String, speechMillis: Long): String {
        val stripped = collapseRepeats(tags.replace(text, " ").replace(Regex("\\s+"), " ").trim())
        val key = stripped.lowercase().trim { !it.isLetterOrDigit() }
        if (speechMillis < 1_200 && key in implausible) return ""
        if (speechMillis < 300 && key in needsRealSpeech) return ""
        return stripped
    }
}

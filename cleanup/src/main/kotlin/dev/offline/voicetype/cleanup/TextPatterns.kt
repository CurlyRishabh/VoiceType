package dev.offline.voicetype.cleanup

/**
 * Regex helpers that treat Devanagari correctly. Java's `\b` is ASCII-only, so it would split
 * Hindi words at vowel signs (matras); these lookarounds use Unicode letter/mark/number classes.
 */
internal object TextPatterns {
    private const val WORD_CHAR = "\\p{L}\\p{M}\\p{N}"

    /** Not preceded by a word character or an apostrophe (so "i" in "didn't" is not a word). */
    const val WB_START = "(?<![$WORD_CHAR'’])"

    /** Not followed by a word character. */
    const val WB_END = "(?![$WORD_CHAR])"

    /** Clause boundaries used by the correction and filler rules. */
    const val CLAUSE_END_CHARS = ".!?;\n।"

    fun words(alternatives: String): Regex =
        Regex("$WB_START(?:$alternatives)$WB_END", RegexOption.IGNORE_CASE)

    fun isWordChar(c: Char): Boolean = Character.isLetterOrDigit(c) || Character.getType(c).let {
        it == Character.NON_SPACING_MARK.toInt() || it == Character.COMBINING_SPACING_MARK.toInt()
    }

    fun isDevanagari(c: Char): Boolean = c in 'ऀ'..'ॿ'
}

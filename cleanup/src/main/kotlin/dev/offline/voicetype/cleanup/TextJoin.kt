package dev.offline.voicetype.cleanup

/** Joins dictated text into existing field content with natural spacing and capitalisation. */
object TextJoin {

    private const val SENTENCE_END = ".!?\n।"
    private const val NO_SPACE_BEFORE = ",.!?;:)]}…।"

    /** True when text inserted after [before] starts a new sentence. */
    fun startsSentence(before: String?): Boolean {
        if (before.isNullOrEmpty()) return true
        if (before.last() == '\n') return true
        val t = before.trimEnd(' ', '\t')
        return t.isEmpty() || t.last() in SENTENCE_END
    }

    /** True when nothing (on the current line) follows the cursor, so a final full stop fits. */
    fun endsSentence(after: String?): Boolean =
        after.isNullOrEmpty() || after.trimStart(' ', '\t').let { it.isEmpty() || it.first() == '\n' }

    /** Adds the spaces needed between [before] + insert + [after]. */
    fun pad(insert: String, before: String?, after: String?): String {
        if (insert.isEmpty()) return insert
        var s = insert
        val b = before.orEmpty()
        if (b.isNotEmpty() && !b.last().isWhitespace() && !s.first().isWhitespace() && s.first() !in NO_SPACE_BEFORE) {
            s = " $s"
        }
        val a = after.orEmpty()
        if (a.isNotEmpty() && !a.first().isWhitespace() && a.first() !in NO_SPACE_BEFORE && !s.last().isWhitespace()) {
            s = "$s "
        }
        return s
    }

    data class Merged(val text: String, val cursor: Int)

    /**
     * Replaces the selection [selStart, selEnd) of [existing] with [insert] (padded), returning the
     * new text and the cursor position right after the inserted text. Out-of-range or missing
     * selections mean "end of text".
     */
    fun merge(existing: String, selStart: Int, selEnd: Int, insert: String): Merged {
        val len = existing.length
        var start = if (selStart in 0..len) selStart else len
        var end = if (selEnd in 0..len) selEnd else start
        if (end < start) start = end.also { end = start }
        val before = existing.substring(0, start)
        val after = existing.substring(end)
        val padded = pad(insert, before, after)
        val text = before + padded + after
        return Merged(text, cursor = before.length + padded.length)
    }
}

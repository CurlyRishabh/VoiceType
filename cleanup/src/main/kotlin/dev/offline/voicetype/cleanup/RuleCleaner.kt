package dev.offline.voicetype.cleanup

import dev.offline.voicetype.cleanup.TextPatterns.WB_END
import dev.offline.voicetype.cleanup.TextPatterns.WB_START

/**
 * Stage 1 cleanup: deterministic, instant, always on. Each rule is a separate public function so
 * it can be unit tested on its own; [clean] runs them in a fixed order.
 */
class RuleCleaner {

    fun clean(input: String, options: CleanupOptions = CleanupOptions()): String {
        var t = normalizeWhitespace(input)
        if (t.isEmpty()) return t
        if (options.applySpokenCommands) t = applySpokenCommands(t)
        if (options.removeFillers) t = removeFillers(t)
        if (options.applySelfCorrections) t = applySelfCorrections(t)
        t = fixSpacingAndPunctuation(t)
        if (options.autoCapitalize) t = capitalize(t, options.startsSentence)
        t = options.dictionary.apply(t)
        if (options.addFinalPunctuation) t = addFinalPunctuation(t)
        return t
    }

    // ---------------------------------------------------------------- whitespace

    fun normalizeWhitespace(text: String): String =
        text.replace("\r\n", "\n")
            .replace(Regex("[\\t\\u00A0\\u200B ]+"), " ")
            .replace(Regex(" *\n *"), "\n")
            .trim()

    // ---------------------------------------------------------------- spoken commands

    private data class Command(val regex: Regex, val replacement: String)

    // Punctuation the recogniser put next to a command word is swallowed by the command.
    private val commands: List<Command> = listOf(
        Command(
            Regex(
                " *,? *$WB_START(?:new|next) paragraph$WB_END[,.;:!?।]* *|" +
                    " *,? *$WB_START(?:naya|nayaa) paragraph$WB_END[,.;:!?।]* *|" +
                    " *,? *नया पैराग्राफ$WB_END[,.;:!?।]* *",
                RegexOption.IGNORE_CASE,
            ),
            "\n\n",
        ),
        Command(
            Regex(
                " *,? *$WB_START(?:new ?line|next line)$WB_END[,.;:!?।]* *|" +
                    " *,? *$WB_START(?:nayi|nai|nyi) line$WB_END[,.;:!?।]* *|" +
                    " *,? *नई लाइन$WB_END[,.;:!?।]* *",
                RegexOption.IGNORE_CASE,
            ),
            "\n",
        ),
        Command(Regex(" *[,.!?]? *${WB_START}question mark$WB_END[,.?]*", RegexOption.IGNORE_CASE), "?"),
        Command(
            Regex(" *[,.!?]? *${WB_START}exclamation (?:mark|point)$WB_END[,.!]*", RegexOption.IGNORE_CASE),
            "!",
        ),
        Command(Regex(" *[,.!?]? *${WB_START}full stop$WB_END[,.]*", RegexOption.IGNORE_CASE), "."),
        // "period" is only a command at the end of a line/utterance and not after words that make
        // it a noun ("the trial period ended", "a long period").
        Command(
            Regex(
                " *[,.]? *(?<!(?:^|\\s)(?:a|the|this|that|each|every|trial|grace|time|waiting|notice|long|short) )" +
                    "${WB_START}period$WB_END[,.!?]*(?= *(?:\n|$))",
                RegexOption.IGNORE_CASE,
            ),
            ".",
        ),
        Command(Regex(" *[,.]? *${WB_START}comma$WB_END[,.]*", RegexOption.IGNORE_CASE), ","),
    )

    fun applySpokenCommands(text: String): String =
        commands.fold(text) { acc, cmd -> cmd.regex.replace(acc, cmd.replacement) }

    // ---------------------------------------------------------------- fillers

    private val alwaysFillers = TextPatterns.words(
        // um, umm, uh, uhh, uhm, er, erm, err, hmm, mm, mmm
        "u+m+|u+h+|u+h+m+|e+r+m*|h+m+|m{2,}",
    )

    // "you know", standalone "like", Hindi "matlab": filler only when set off by commas or at the
    // edge of a clause, so "do you know him", "I like it" and "iska matlab kya hai" are untouched.
    private val discourseMarkers = listOf("you know", "like", "matlab", "मतलब")

    private val haanToh = Regex(
        "(^|[.!?;\\n।] *)$WB_START(?:haan|han|haa|हाँ|हां) +(?:toh|to|तो)$WB_END,? *",
        RegexOption.IGNORE_CASE,
    )

    fun removeFillers(text: String): String {
        var t = alwaysFillers.replace(text, "")
        for (marker in discourseMarkers) t = removeDiscourseMarker(t, marker)
        t = haanToh.replace(t) { it.groupValues[1] }
        return tidyAfterRemoval(t)
    }

    private fun removeDiscourseMarker(text: String, marker: String): String {
        val m = marker.split(' ').joinToString(" +") { Regex.escape(it) }
        var t = text
        // ", you know," -> " "
        t = Regex(", *$WB_START$m$WB_END *,", RegexOption.IGNORE_CASE).replace(t, " ")
        // "You know, ..." at the start of a clause
        t = Regex("(^|[.!?;\\n।] *)$WB_START$m$WB_END *, *", RegexOption.IGNORE_CASE)
            .replace(t) { it.groupValues[1] }
        // "..., you know." at the end of a clause
        t = Regex(", *$WB_START$m$WB_END *(?=[.!?;\\n।]|$)", RegexOption.IGNORE_CASE).replace(t, "")
        // Doubled marker: "like like", "matlab matlab"
        t = Regex("$WB_START$m +$m$WB_END", RegexOption.IGNORE_CASE).replace(t, "")
        return t
    }

    /** Removes the comma/space debris a deleted word leaves behind. */
    private fun tidyAfterRemoval(text: String): String =
        text.replace(Regex(" {2,}"), " ")
            .replace(Regex(" +([,.!?;:।])"), "$1")
            .replace(Regex(",(?: *,)+"), ",")
            .replace(Regex("(^|[.!?;\\n।])( *)(?:, *)+"), "$1$2")
            .replace(Regex(",+([.!?;।])"), "$1")
            .replace(Regex(" *\n *"), "\n")
            .trim()

    // ---------------------------------------------------------------- self-corrections

    private val correctionMarker = Regex(
        "[,;]? *$WB_START(?:" +
            "no,? +wait|wait,? +no|" +
            "actually,? +no|" +
            "sorry,? +i +mean|" +
            "i +mean|" +
            "nahi?n?,? +nahi?n?|" +
            "नहीं,? +नहीं|नही,? +नही" +
            ")$WB_END[,.;]? *",
        RegexOption.IGNORE_CASE,
    )

    private val notACorrectionBefore = setOf("what", "which", "that", "if")
    private val notACorrectionAfter = setOf("it", "that", "this", "what", "to", "well", "business")
    private val noWaitNouns = setOf("time", "times", "list", "lists")

    /**
     * "X no wait Y", "X I mean Y", "X nahi nahi Y" -> keep Y. The replaced span of X is found by
     * aligning the first words of Y with the end of X ("meet at 5 no wait at 6" -> "meet at 6");
     * without an alignment, Y replaces the single word before the marker
     * ("send it to John no wait Mary" -> "send it to Mary").
     */
    fun applySelfCorrections(text: String): String {
        var t = text
        var searchFrom = 0
        var guard = 0
        while (guard++ < 50) {
            val m = correctionMarker.find(t, searchFrom) ?: break
            var clauseStart = t.lastIndexOfAny(TextPatterns.CLAUSE_END_CHARS.toCharArray(), m.range.first - 1)
                .let { if (it < 0) 0 else it + 1 }
            var left = t.substring(clauseStart, m.range.first)
            var leftWords = WORD_SPAN.findAll(left).toList()
            val strongMarker = "mean" !in m.value.lowercase() || "sorry" in m.value.lowercase()
            // The recogniser often ends a sentence right before the correction ("at 5. No wait. 6"):
            // let a strong marker reach back into the previous sentence.
            if (leftWords.isEmpty() && strongMarker && clauseStart >= 2 && t[clauseStart - 1] in ".!?।") {
                val prevStart = t.lastIndexOfAny(TextPatterns.CLAUSE_END_CHARS.toCharArray(), clauseStart - 2)
                    .let { if (it < 0) 0 else it + 1 }
                left = t.substring(prevStart, clauseStart - 1)
                leftWords = WORD_SPAN.findAll(left).toList()
                clauseStart = prevStart
            }

            val nextBoundary = t.indexOfAny(TextPatterns.CLAUSE_END_CHARS.toCharArray(), m.range.last + 1)
                .let { if (it < 0) t.length else it }
            val rightClause = t.substring(m.range.last + 1, nextBoundary)
            val rightWords = WORD_SPAN.findAll(rightClause).map { norm(it.value) }.filter { it.isNotEmpty() }.toList()

            val markerText = m.value.lowercase()
            val isIMean = "mean" in markerText
            val prevWord = leftWords.lastOrNull()?.value?.let(::norm)

            val firstRight = rightWords.firstOrNull()
            val notACorrection =
                (isIMean && prevWord != null && prevWord in notACorrectionBefore) || // "what I mean is"
                    (isIMean && firstRight in notACorrectionAfter) ||                 // "I mean it"
                    (isIMean && leftWords.isEmpty() && ',' !in markerText) ||         // "I mean it's fine"
                    ("wait" in markerText && firstRight in noWaitNouns)               // "no wait time"
            if (notACorrection) {
                searchFrom = m.range.last + 1
                continue
            }
            if (rightWords.isEmpty()) {
                // Marker with nothing after it: just drop the marker.
                t = t.substring(0, m.range.first) + t.substring(m.range.last + 1)
                searchFrom = m.range.first
                continue
            }
            if (leftWords.isEmpty()) {
                // Clause starts with the marker ("I mean, it's fine"): drop it as a filler.
                t = t.substring(0, m.range.first).trimEnd(' ') +
                    (if (m.range.first > 0 && !t[m.range.first - 1].isWhitespace()) " " else "") +
                    t.substring(m.range.last + 1)
                searchFrom = clauseStart
                continue
            }

            val leftNorm = leftWords.map { norm(it.value) }
            var cut = leftWords.size - 1 // default: replace the single word before the marker
            for (i in 0 until minOf(rightWords.size, 3)) {
                val p = leftNorm.lastIndexOf(rightWords[i])
                if (p >= 0 && p - i >= 0) {
                    cut = p - i
                    break
                }
            }
            val keptLeft = t.substring(clauseStart, clauseStart + leftWords[cut].range.first).trimEnd(' ', ',')
            val prefix = t.substring(0, clauseStart)
            val rest = t.substring(m.range.last + 1).trimStart(' ', ',')
            val joiner = if (keptLeft.isEmpty()) "" else " "
            val leadingSpace = if (keptLeft.isEmpty() && prefix.isNotEmpty() && !prefix.last().isWhitespace()) " " else ""
            t = prefix + leadingSpace + keptLeft + joiner + rest
            searchFrom = (prefix + leadingSpace + keptLeft + joiner).length
        }
        return t
    }

    private fun norm(word: String): String =
        word.lowercase().filter { TextPatterns.isWordChar(it) || it == '\'' }

    // ---------------------------------------------------------------- spacing & punctuation

    fun fixSpacingAndPunctuation(text: String): String {
        var t = text.replace(Regex("[ \\t]+"), " ")
        t = t.replace(Regex(" +([,.!?;:।])"), "$1")          // no space before punctuation
        t = t.replace(Regex(",(?: *,)+"), ",")                // ",," / ", ,"
        t = t.replace(Regex(",+ *([.!?;।])"), "$1")           // ",." -> "."
        t = t.replace(Regex("([!?])\\.+"), "$1")              // "?." -> "?"
        t = t.replace(Regex("(?<!\\.)\\.\\.(?!\\.)"), ".")    // ".." -> "." (keeps "...")
        t = t.replace(Regex("([,;!?])(?=\\p{L})"), "$1 ")     // space after punctuation before a word
        t = t.replace(Regex("(?m)^[ ,;:]+"), "")             // no punctuation at line start
        t = t.replace(Regex(" *\n *"), "\n")
        t = t.replace(Regex("\n{3,}"), "\n\n")
        return t.trim(' ')
    }

    // ---------------------------------------------------------------- capitalisation

    private val sentenceStart = Regex("(^|[.!?।] +|\n *)(\\p{Ll})")
    private val abbreviationEnd = Regex("(?i)(?:^|\\s)(?:i\\.e|e\\.g|vs|approx|et al)\\.$")
    private val loneI = Regex("$WB_START" + "i" + "(?!\\.e\\.)$WB_END")

    fun capitalize(text: String, startsSentence: Boolean = true): String {
        var t = sentenceStart.replace(text) { m ->
            val atTextStart = m.range.first == 0 && m.groupValues[1].isEmpty()
            val afterAbbreviation = abbreviationEnd.containsMatchIn(text.substring(0, m.range.first + 1))
            if ((atTextStart && !startsSentence) || afterAbbreviation) {
                m.value
            } else {
                m.groupValues[1] + m.groupValues[2].uppercase()
            }
        }
        t = loneI.replace(t, "I")
        return t
    }

    // ---------------------------------------------------------------- final punctuation

    fun addFinalPunctuation(text: String): String {
        if (text.isEmpty()) return text
        val last = text.last()
        if (!TextPatterns.isWordChar(last)) return text
        val lastLetter = text.lastOrNull { Character.isLetter(it) }
        val stop = if (lastLetter != null && TextPatterns.isDevanagari(lastLetter)) "।" else "."
        return text + stop
    }

    companion object {
        private val WORD_SPAN = Regex("[^\\s,;:]+")
    }
}

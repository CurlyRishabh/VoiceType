package dev.offline.voicetype.cleanup

/**
 * Sanity checks on LLM output. Small models occasionally translate, answer the dictated question,
 * or invent text; when that happens we fall back to the Stage 1 result.
 */
object PolishGuard {

    sealed class Verdict {
        data object Accept : Verdict()
        data class Reject(val reason: String) : Verdict()
    }

    private val assistantPhrases = Regex(
        "^(?:i'm sorry|i am sorry|as an ai|i cannot|i can't help|sure[,!]|certainly[,!]|of course[,!])",
        RegexOption.IGNORE_CASE,
    )

    fun check(input: String, output: String, style: PolishStyle): Verdict {
        val inLen = input.length
        val outLen = output.length
        if (output.isBlank()) return Verdict.Reject("empty output")
        if (assistantPhrases.containsMatchIn(output.trimStart()) && !assistantPhrases.containsMatchIn(input.trimStart())) {
            return Verdict.Reject("answered like an assistant")
        }
        val slack = if (style == PolishStyle.NOTES) 60 else 40
        if (outLen > inLen * 2 + slack) return Verdict.Reject("output much longer than input")
        if (inLen >= 20 && outLen < inLen * 0.4) return Verdict.Reject("output dropped too much")

        val inDeva = devanagariRatio(input)
        val outDeva = devanagariRatio(output)
        if (kotlin.math.abs(inDeva - outDeva) > 0.5) return Verdict.Reject("changed script (translated?)")

        val inWords = contentWords(input).toSet()
        val outWords = contentWords(output)
        if (outWords.size >= 4) {
            val known = outWords.count { it in inWords || inWords.any { w -> similar(w, it) } }
            if (known.toDouble() / outWords.size < 0.5) return Verdict.Reject("added or translated content")
        }
        return Verdict.Accept
    }

    private fun devanagariRatio(text: String): Double {
        val letters = text.filter { Character.isLetter(it) }
        if (letters.isEmpty()) return 0.0
        return letters.count { it in 'ऀ'..'ॿ' }.toDouble() / letters.length
    }

    private fun contentWords(text: String): List<String> =
        Regex("[\\p{L}\\p{M}\\p{N}']+").findAll(text.lowercase()).map { it.value }.filter { it.length > 2 }.toList()

    /** Tolerates spelling fixes ("miting" -> "meeting", "recieve" -> "receive"). */
    private fun similar(a: String, b: String): Boolean {
        if (kotlin.math.abs(a.length - b.length) > 2) return false
        return levenshtein(a, b) <= maxOf(1, minOf(a.length, b.length) / 3)
    }

    private fun levenshtein(a: String, b: String): Int {
        var prev = IntArray(b.length + 1) { it }
        var cur = IntArray(b.length + 1)
        for (i in 1..a.length) {
            cur[0] = i
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            val tmp = prev; prev = cur; cur = tmp
        }
        return prev[b.length]
    }
}

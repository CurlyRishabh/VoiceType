package dev.offline.voicetype.cleanup

/**
 * User-defined replacements, e.g. "acme" -> "Acme" or "acme h q" -> "AcmeHQ".
 * Matching is case-insensitive, whole-word, and tolerant of extra whitespace between words.
 */
class PersonalDictionary(entries: List<Entry>) {

    data class Entry(val from: String, val to: String)

    val entries: List<Entry> = entries
        .map { Entry(sanitize(it.from), sanitize(it.to)) }
        .filter { it.from.isNotEmpty() && it.to.isNotEmpty() }
        .distinctBy { it.from.lowercase() }

    // Longer phrases first so "new york times" wins over "new york".
    private val compiled: List<Pair<Regex, String>> = this.entries
        .sortedByDescending { it.from.length }
        .map { entry ->
            val body = entry.from.split(Regex("\\s+")).joinToString("\\s+") { Regex.escape(it) }
            TextPatterns.words(body) to entry.to
        }

    fun apply(text: String): String =
        compiled.fold(text) { acc, (regex, replacement) ->
            regex.replace(acc, Regex.escapeReplacement(replacement))
        }

    fun isEmpty(): Boolean = entries.isEmpty()

    /** One entry per line: `from<TAB>to`. */
    fun serialize(): String = entries.joinToString("\n") { "${it.from}\t${it.to}" }

    fun plus(entry: Entry): PersonalDictionary =
        PersonalDictionary(entries.filterNot { it.from.equals(entry.from.trim(), ignoreCase = true) } + entry)

    fun minus(from: String): PersonalDictionary =
        PersonalDictionary(entries.filterNot { it.from.equals(from, ignoreCase = true) })

    companion object {
        val EMPTY = PersonalDictionary(emptyList())

        fun parse(serialized: String?): PersonalDictionary {
            if (serialized.isNullOrBlank()) return EMPTY
            val entries = serialized.lineSequence().mapNotNull { line ->
                val parts = line.split('\t')
                if (parts.size == 2) Entry(parts[0], parts[1]) else null
            }.toList()
            return PersonalDictionary(entries)
        }

        private fun sanitize(s: String): String = s.replace(Regex("[\\t\\r\\n]+"), " ").trim()
    }
}

package dev.offline.voicetype.cleanup

/**
 * Devanagari -> casual Latin ("Hinglish" chat spelling), e.g. "मुझे कल मीटिंग में जाना है" ->
 * "mujhe kal meeting mein jaana hai"-style output. Whisper writes Hindi speech in Devanagari;
 * this lets the user choose Latin output. Text that is already Latin passes through unchanged.
 *
 * Implements Hindi schwa deletion (करना -> karna, समझना -> samajhna, मतलब -> matlab) so the
 * output reads the way people type Hinglish, not like a formal transliteration scheme.
 */
object Transliterator {

    fun containsDevanagari(text: String): Boolean = text.any { it in 'ऀ'..'ॿ' }

    fun toLatin(text: String): String {
        if (!containsDevanagari(text)) return text
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (isDevanagariWordChar(c)) {
                val start = i
                while (i < text.length && isDevanagariWordChar(text[i])) i++
                out.append(transliterateWord(text.substring(start, i)))
            } else {
                out.append(PUNCT[c] ?: c.toString())
                i++
            }
        }
        return out.toString()
    }

    // ------------------------------------------------------------------ model

    private enum class Kind { CONSONANT, VOWEL, NASAL, VISARGA, OTHER }

    /**
     * A consonant carries its vowel: [vowel] is "a" (inherent schwa), a matra's Latin value,
     * or null after a halant (part of a conjunct).
     */
    private class Unit(val kind: Kind, var latin: String, var vowel: String? = null) {
        var vowelIsSchwa = false
        var vowelIsLong = false // ा ी ू – affects word-final shortening
        val hasVowel get() = kind == Kind.VOWEL || (kind == Kind.CONSONANT && vowel != null)
    }

    private fun transliterateWord(word: String): String {
        val units = parse(word)
        deleteSchwas(units)
        return render(units)
    }

    private fun parse(word: String): MutableList<Unit> {
        val units = mutableListOf<Unit>()
        var i = 0
        while (i < word.length) {
            val c = word[i]
            when {
                c in CONSONANTS -> {
                    var latin = CONSONANTS.getValue(c)
                    if (i + 1 < word.length && word[i + 1] == NUKTA) {
                        latin = NUKTA_FORMS[c] ?: latin
                        i++
                    }
                    units += Unit(Kind.CONSONANT, latin, "a").apply { vowelIsSchwa = true }
                }
                c == NUKTA -> Unit(Kind.OTHER, "") // stray nukta: ignore
                c == HALANT -> units.lastOrNull()?.takeIf { it.kind == Kind.CONSONANT }?.let {
                    it.vowel = null
                    it.vowelIsSchwa = false
                }
                c in MATRAS -> units.lastOrNull()?.takeIf { it.kind == Kind.CONSONANT }?.let {
                    it.vowel = MATRAS.getValue(c)
                    it.vowelIsSchwa = false
                    it.vowelIsLong = c in LONG_MATRAS
                }
                c in VOWELS -> units += Unit(Kind.VOWEL, VOWELS.getValue(c))
                c == ANUSVARA || c == CHANDRABINDU -> units += Unit(Kind.NASAL, "n")
                c == VISARGA -> units += Unit(Kind.VISARGA, "h")
                c == '‌' || c == '‍' || c == AVAGRAHA -> Unit(Kind.OTHER, "")
                c in DIGITS -> units += Unit(Kind.OTHER, DIGITS.getValue(c))
                c == '\u0950' -> units += Unit(Kind.OTHER, "om")
                else -> units += Unit(Kind.OTHER, "")
            }
            i++
        }
        return units
    }

    private fun deleteSchwas(units: MutableList<Unit>) {
        val consonantCount = units.count { it.kind == Kind.CONSONANT }
        val lastSyllableIdx = units.indexOfLast { it.kind == Kind.CONSONANT || it.kind == Kind.VOWEL }
        if (lastSyllableIdx < 0) return

        // Word-final schwa: "kamal", "kaam". Kept for single-syllable words ("na") and after
        // conjuncts ending in y/r/v ("mitra", "kaavya").
        val last = units[lastSyllableIdx]
        if (last.kind == Kind.CONSONANT && last.vowelIsSchwa && consonantCount + units.count { it.kind == Kind.VOWEL } > 1) {
            val prev = units.getOrNull(lastSyllableIdx - 1)
            val afterConjunct = prev != null && prev.kind == Kind.CONSONANT && prev.vowel == null
            if (!(afterConjunct && last.latin in setOf("y", "r", "v"))) last.vowel = null
        }

        // Medial schwa (right to left): V C a C V -> V C C V ("karana" -> "karna").
        for (i in lastSyllableIdx - 1 downTo 1) {
            val u = units[i]
            if (u.kind != Kind.CONSONANT || !u.vowelIsSchwa || u.vowel == null) continue
            val prev = units[i - 1]
            val next = units.getOrNull(i + 1) ?: continue
            if (prev.hasVowel && next.kind == Kind.CONSONANT && next.vowel != null) {
                u.vowel = null
            }
        }
    }

    private fun render(units: List<Unit>): String {
        val sb = StringBuilder()
        val lastSyllableIdx = units.indexOfLast { it.kind == Kind.CONSONANT || it.kind == Kind.VOWEL }
        for ((i, u) in units.withIndex()) {
            when (u.kind) {
                Kind.CONSONANT -> {
                    sb.append(u.latin)
                    var v = u.vowel ?: ""
                    val nasalFollows = units.getOrNull(i + 1)?.kind == Kind.NASAL
                    if (i == lastSyllableIdx && u.vowelIsLong && !nasalFollows) {
                        v = SHORT_FINAL[v] ?: v // "tha", "abhi", "tu"
                    } else if (i == lastSyllableIdx && u.vowelIsLong && nasalFollows && v == "ee") {
                        v = "i" // "nahin"
                    }
                    if (v == "e" && nasalFollows && i == lastSyllableIdx) v = "ei" // "mein"
                    sb.append(v)
                }
                Kind.NASAL -> {
                    val next = units.getOrNull(i + 1)
                    val labial = next?.kind == Kind.CONSONANT && next.latin.firstOrNull() in setOf('p', 'b', 'm')
                    sb.append(if (labial) "m" else "n")
                }
                else -> sb.append(u.latin)
            }
        }
        return sb.toString()
    }

    private fun isDevanagariWordChar(c: Char): Boolean =
        (c in 'ऀ'..'ॿ' && c != '।' && c != '॥') || c == '‌' || c == '‍'

    // ------------------------------------------------------------------ tables

    private const val HALANT = '्'
    private const val NUKTA = '़'
    private const val ANUSVARA = 'ं'
    private const val CHANDRABINDU = 'ँ'
    private const val VISARGA = 'ः'
    private const val AVAGRAHA = 'ऽ'

    private val CONSONANTS = mapOf(
        'क' to "k", 'ख' to "kh", 'ग' to "g", 'घ' to "gh", 'ङ' to "n",
        'च' to "ch", 'छ' to "chh", 'ज' to "j", 'झ' to "jh", 'ञ' to "n",
        'ट' to "t", 'ठ' to "th", 'ड' to "d", 'ढ' to "dh", 'ण' to "n",
        'त' to "t", 'थ' to "th", 'द' to "d", 'ध' to "dh", 'न' to "n",
        'प' to "p", 'फ' to "ph", 'ब' to "b", 'भ' to "bh", 'म' to "m",
        'य' to "y", 'र' to "r", 'ल' to "l", 'ळ' to "l", 'व' to "v",
        'श' to "sh", 'ष' to "sh", 'स' to "s", 'ह' to "h",
        // precomposed nukta letters (escaped so source normalisation can't split them)
        '\u0958' to "q", '\u0959' to "kh", '\u095A' to "g", '\u095B' to "z",
        '\u095C' to "r", '\u095D' to "rh", '\u095E' to "f", '\u095F' to "y",
    )

    private val NUKTA_FORMS = mapOf('क' to "q", 'ख' to "kh", 'ग' to "g", 'ज' to "z", 'ड' to "r", 'ढ' to "rh", 'फ' to "f")

    private val VOWELS = mapOf(
        'अ' to "a", 'आ' to "aa", 'इ' to "i", 'ई' to "ee", 'उ' to "u", 'ऊ' to "oo", 'ऋ' to "ri",
        'ए' to "e", 'ऐ' to "ai", 'ओ' to "o", 'औ' to "au", 'ऑ' to "o", 'ऍ' to "e",
    )

    private val MATRAS = mapOf(
        'ा' to "aa", 'ि' to "i", 'ी' to "ee", 'ु' to "u", 'ू' to "oo", 'ृ' to "ri",
        'े' to "e", 'ै' to "ai", 'ो' to "o", 'ौ' to "au", 'ॉ' to "o", 'ॅ' to "e",
    )

    private val LONG_MATRAS = setOf('ा', 'ी', 'ू')
    private val SHORT_FINAL = mapOf("aa" to "a", "ee" to "i", "oo" to "u")

    private val DIGITS = mapOf(
        '०' to "0", '१' to "1", '२' to "2", '३' to "3", '४' to "4",
        '५' to "5", '६' to "6", '७' to "7", '८' to "8", '९' to "9",
    )

    private val PUNCT = mapOf('।' to ".", '॥' to ".")
}

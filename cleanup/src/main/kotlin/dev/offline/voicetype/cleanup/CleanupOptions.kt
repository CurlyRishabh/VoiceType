package dev.offline.voicetype.cleanup

/** Toggles for the Stage 1 rules. Stage 1 itself always runs; individual rules can be disabled. */
data class CleanupOptions(
    val removeFillers: Boolean = true,
    val applySelfCorrections: Boolean = true,
    val applySpokenCommands: Boolean = true,
    val autoCapitalize: Boolean = true,
    val addFinalPunctuation: Boolean = true,
    val dictionary: PersonalDictionary = PersonalDictionary.EMPTY,
    /**
     * False when the text is inserted mid-sentence (the text before the cursor does not end
     * with sentence punctuation), so the first word is not force-capitalised.
     */
    val startsSentence: Boolean = true,
)

enum class OutputScript { LATIN, DEVANAGARI }

enum class PolishStyle { CASUAL, PROFESSIONAL, NOTES }

/** Everything the pipeline needs for one utterance. */
data class CleanupSettings(
    val options: CleanupOptions = CleanupOptions(),
    val script: OutputScript = OutputScript.LATIN,
    val polishEnabled: Boolean = false,
    val polishStyle: PolishStyle = PolishStyle.CASUAL,
)

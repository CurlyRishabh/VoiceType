package dev.offline.voicetype.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.preference.PreferenceManager
import dev.offline.voicetype.cleanup.CleanupOptions
import dev.offline.voicetype.cleanup.CleanupSettings
import dev.offline.voicetype.cleanup.OutputScript
import dev.offline.voicetype.cleanup.PersonalDictionary
import dev.offline.voicetype.cleanup.PolishStyle
import dev.offline.voicetype.engine.EngineKind
import dev.offline.voicetype.engine.EngineSpec

/** Typed access to SharedPreferences (stored in app-private storage, excluded from backup). */
class Settings(context: Context) {

    val prefs: SharedPreferences = PreferenceManager.getDefaultSharedPreferences(context)

    /** "en", "hi" or "auto". */
    val language: String get() = prefs.getString(KEY_LANGUAGE, "en") ?: "en"

    /** Engine the user picked for English. Hindi/auto always use the multilingual model. */
    val englishEngine: EngineKind
        get() = if (prefs.getString(KEY_ENGINE, "fast_english") == "hindi_english") EngineKind.HINDI_ENGLISH else EngineKind.FAST_ENGLISH

    fun engineSpec(): EngineSpec = when (language) {
        "hi" -> EngineSpec(EngineKind.HINDI_ENGLISH, language = "hi")
        "auto" -> EngineSpec(EngineKind.HINDI_ENGLISH, language = "")
        else -> EngineSpec(englishEngine, language = "en")
    }

    val script: OutputScript
        get() = if (prefs.getString(KEY_SCRIPT, "latin") == "devanagari") OutputScript.DEVANAGARI else OutputScript.LATIN

    val silenceMillis: Int get() = prefs.getInt(KEY_SILENCE_MS, 1_500).coerceIn(500, 5_000)

    val removeFillers get() = prefs.getBoolean(KEY_FILLERS, true)
    val selfCorrections get() = prefs.getBoolean(KEY_CORRECTIONS, true)
    val spokenCommands get() = prefs.getBoolean(KEY_COMMANDS, true)
    val autoCapitalize get() = prefs.getBoolean(KEY_CAPITALIZE, true)
    val finalPunctuation get() = prefs.getBoolean(KEY_FINAL_PUNCT, true)

    val polishEnabled get() = prefs.getBoolean(KEY_POLISH, true)
    val polishGpu get() = prefs.getBoolean(KEY_POLISH_GPU, false)
    val polishStyle: PolishStyle
        get() = when (prefs.getString(KEY_POLISH_STYLE, "casual")) {
            "professional" -> PolishStyle.PROFESSIONAL
            "notes" -> PolishStyle.NOTES
            else -> PolishStyle.CASUAL
        }

    var bubbleEnabled: Boolean
        get() = prefs.getBoolean(KEY_BUBBLE, false)
        set(v) = prefs.edit { putBoolean(KEY_BUBBLE, v) }
    val bubbleHideWithKeyboard get() = prefs.getBoolean(KEY_BUBBLE_HIDE, false)
    val bubbleHoldToTalk get() = prefs.getString(KEY_BUBBLE_MODE, "toggle") == "hold"
    var bubbleX: Int
        get() = prefs.getInt(KEY_BUBBLE_X, -1)
        set(v) = prefs.edit { putInt(KEY_BUBBLE_X, v) }
    var bubbleY: Int
        get() = prefs.getInt(KEY_BUBBLE_Y, 400)
        set(v) = prefs.edit { putInt(KEY_BUBBLE_Y, v) }

    val historyEnabled get() = prefs.getBoolean(KEY_HISTORY, true)
    val keepRecordings get() = prefs.getBoolean(KEY_KEEP_RECORDINGS, false)

    var dictionary: PersonalDictionary
        get() = PersonalDictionary.parse(prefs.getString(KEY_DICTIONARY, null))
        set(v) = prefs.edit { putString(KEY_DICTIONARY, v.serialize()) }

    /**
     * Builds the per-utterance cleanup settings. [plainText] is false for password/email/URL
     * fields, where capitalisation, final punctuation and AI polish would do harm.
     */
    fun cleanupSettings(
        startsSentence: Boolean,
        endsSentence: Boolean,
        plainText: Boolean,
        polishAvailable: Boolean,
    ): CleanupSettings = CleanupSettings(
        options = CleanupOptions(
            removeFillers = removeFillers,
            applySelfCorrections = selfCorrections,
            applySpokenCommands = spokenCommands,
            autoCapitalize = autoCapitalize && plainText,
            addFinalPunctuation = finalPunctuation && endsSentence && plainText,
            dictionary = dictionary,
            startsSentence = startsSentence,
        ),
        script = script,
        polishEnabled = polishEnabled && plainText && polishAvailable,
        polishStyle = polishStyle,
    )

    companion object {
        const val KEY_LANGUAGE = "language"
        const val KEY_ENGINE = "engine"
        const val KEY_SCRIPT = "script"
        const val KEY_SILENCE_MS = "silence_ms"
        const val KEY_FILLERS = "rule_fillers"
        const val KEY_CORRECTIONS = "rule_corrections"
        const val KEY_COMMANDS = "rule_commands"
        const val KEY_CAPITALIZE = "rule_capitalize"
        const val KEY_FINAL_PUNCT = "rule_final_punct"
        const val KEY_POLISH = "polish_enabled"
        const val KEY_POLISH_STYLE = "polish_style"
        const val KEY_POLISH_GPU = "polish_gpu"
        const val KEY_BUBBLE = "bubble_enabled"
        const val KEY_BUBBLE_HIDE = "bubble_hide_with_keyboard"
        const val KEY_BUBBLE_MODE = "bubble_mode"
        const val KEY_BUBBLE_X = "bubble_x"
        const val KEY_BUBBLE_Y = "bubble_y"
        const val KEY_HISTORY = "history_enabled"
        const val KEY_KEEP_RECORDINGS = "keep_recordings"
        const val KEY_DICTIONARY = "dictionary"
    }
}

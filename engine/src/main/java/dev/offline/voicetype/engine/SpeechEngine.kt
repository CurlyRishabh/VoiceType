package dev.offline.voicetype.engine

import java.io.Closeable

/** Speech-to-text backend. Implementations are not thread-safe; [SpeechEngineHost] serialises calls. */
interface SpeechEngine : Closeable {
    val spec: EngineSpec

    /** Transcribes one chunk of 16 kHz mono audio (at most ~30 s). */
    fun transcribe(samples: FloatArray, sampleRate: Int = SAMPLE_RATE): String
}

enum class EngineKind {
    /** Moonshine Base English (int8): fastest, English only. */
    FAST_ENGLISH,

    /** Multilingual Whisper small (int8): Hindi, English and Hinglish. */
    HINDI_ENGLISH,
}

/** Whisper language: "en", "hi", or "" for auto-detect. Ignored by Moonshine. */
data class EngineSpec(val kind: EngineKind, val language: String = "en", val threads: Int = 4)

const val SAMPLE_RATE = 16_000

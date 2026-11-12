package dev.offline.voicetype.cleanup

/** A prompt for the on-device LLM: system instruction + user turn + an output budget. */
data class PolishRequest(
    val systemInstruction: String,
    val userMessage: String,
    val maxOutputTokens: Int,
)

/**
 * Stage 2 backend (implemented in :polish with LiteRT-LM). Kept as an interface so the pipeline
 * and its timeout/fallback logic are unit tested with fakes on the JVM.
 */
interface Polisher {
    /** True when a model is loaded and [polish] can run right now. */
    val isReady: Boolean

    /** Starts loading the model in the background if it is not loaded. Must not block. */
    fun warmUp()

    /** Blocking. Returns the raw model output. May throw. */
    fun polish(request: PolishRequest): String

    /** Cancels an in-flight [polish] call from another thread. */
    fun cancel()
}

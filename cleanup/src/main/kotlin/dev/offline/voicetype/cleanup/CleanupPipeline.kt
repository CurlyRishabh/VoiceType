package dev.offline.voicetype.cleanup

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

data class CleanupResult(
    val raw: String,
    val stage1: String,
    val text: String,
    val polished: Boolean,
    val polishMillis: Long = 0,
    /** Why Stage 2 was skipped or discarded, for the debug screen. Null when polish was used or off. */
    val fallbackReason: String? = null,
)

/**
 * raw ASR text -> (optional Devanagari->Latin) -> Stage 1 rules -> (optional) Stage 2 LLM polish.
 * Stage 2 has a hard timeout; on timeout, error, or a failed sanity check the Stage 1 text is used.
 */
class CleanupPipeline(
    private val polisher: Polisher?,
    private val timeoutMillis: Long = 3_000,
    private val cleaner: RuleCleaner = RuleCleaner(),
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "polish").apply { isDaemon = true }
    },
) {

    fun process(raw: String, settings: CleanupSettings): CleanupResult {
        val scripted = if (settings.script == OutputScript.LATIN) Transliterator.toLatin(raw) else raw
        val stage1 = cleaner.clean(scripted, settings.options)

        if (!settings.polishEnabled || polisher == null) return CleanupResult(raw, stage1, stage1, polished = false)
        if (stage1.isBlank()) return CleanupResult(raw, stage1, stage1, polished = false)
        if (!polisher.isReady) {
            polisher.warmUp()
            return CleanupResult(raw, stage1, stage1, polished = false, fallbackReason = "polish model not loaded yet")
        }

        val request = PolishPrompt.build(stage1, settings.polishStyle, settings.script)
        val started = System.nanoTime()
        val future = executor.submit<String> { polisher.polish(request) }
        val output = try {
            future.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            polisher.cancel()
            future.cancel(true)
            return CleanupResult(raw, stage1, stage1, false, elapsed(started), "polish timed out after ${timeoutMillis}ms")
        } catch (e: Exception) {
            val cause = (e.cause ?: e)
            return CleanupResult(raw, stage1, stage1, false, elapsed(started), "polish failed: ${cause.javaClass.simpleName}: ${cause.message}")
        }
        val millis = elapsed(started)

        var polished = PolishPrompt.extract(output)
        when (val verdict = PolishGuard.check(stage1, polished, settings.polishStyle)) {
            is PolishGuard.Verdict.Reject -> return CleanupResult(raw, stage1, stage1, false, millis, "polish rejected: ${verdict.reason}")
            PolishGuard.Verdict.Accept -> Unit
        }
        // The model may "fix" the user's custom spellings; the dictionary always wins.
        polished = settings.options.dictionary.apply(polished)
        // Mid-sentence insertion: don't let the model capitalise the first word if Stage 1 didn't.
        if (!settings.options.startsSentence && stage1.firstOrNull()?.isLowerCase() == true &&
            polished.firstOrNull()?.lowercaseChar() == stage1.first()
        ) {
            polished = polished.first().lowercaseChar() + polished.substring(1)
        }
        return CleanupResult(raw, stage1, polished, polished = true, polishMillis = millis)
    }

    fun shutdown() = executor.shutdownNow()

    private fun elapsed(startNanos: Long) = (System.nanoTime() - startNanos) / 1_000_000
}

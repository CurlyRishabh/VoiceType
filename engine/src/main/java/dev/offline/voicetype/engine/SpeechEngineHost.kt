package dev.offline.voicetype.engine

import android.content.ComponentCallbacks2
import android.util.Log
import java.io.File
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Owns the loaded speech model. Every load / decode / release runs on ONE background thread, so a
 * release (memory pressure, idle timeout) can never free native memory under a running decode.
 *
 * - Kept warm while a client (keyboard, bubble, recognition service) is active.
 * - Released 5 minutes after the last use, and on memory pressure when no client is active.
 */
class SpeechEngineHost(
    private val modelsRoot: File,
    private val idleReleaseMillis: Long = 5 * 60_000L,
    private val factory: (EngineSpec, File) -> SpeechEngine = { spec, root -> SherpaSpeechEngine.create(spec, root) },
) {

    data class Transcript(
        val text: String,
        val audioMillis: Long,
        val decodeMillis: Long,
        val loadMillis: Long,
        val engine: EngineSpec,
    ) {
        /** Real-time factor: decode time / audio time (lower is faster; < 1 is faster than real time). */
        val rtf: Double get() = if (audioMillis == 0L) 0.0 else decodeMillis.toDouble() / audioMillis
    }

    private val executor = ScheduledThreadPoolExecutor(1) { r ->
        Thread(r, "speech-engine").apply { priority = Thread.NORM_PRIORITY + 1 }
    }.apply { removeOnCancelPolicy = true }

    // Touched only on the executor thread.
    private var engine: SpeechEngine? = null
    private var idleRelease: ScheduledFuture<*>? = null

    private val activeClients = AtomicInteger(0)

    @Volatile var lastLoadMillis: Long = 0
        private set

    @Volatile var loadedSpec: EngineSpec? = null
        private set

    fun clientActive() { activeClients.incrementAndGet() }
    fun clientInactive() { activeClients.updateAndGet { maxOf(0, it - 1) } }

    /** Loads [spec] in the background so the first dictation is fast. */
    fun warmUp(spec: EngineSpec) {
        executor.execute { runCatching { ensureLoaded(spec) }.onFailure { Log.w(TAG, "warm-up failed: ${it.message}") } }
    }

    /** Decodes the chunks in order and joins the text. The future throws if the model is missing. */
    fun transcribe(spec: EngineSpec, chunks: List<FloatArray>, audioMillis: Long): Future<Transcript> = executor.submit<Transcript> {
        val load = ensureLoaded(spec)
        val e = engine!!
        val started = System.nanoTime()
        val text = chunks.joinToString(" ") { e.transcribe(it) }.replace(Regex("\\s+"), " ").trim()
        val decode = (System.nanoTime() - started) / 1_000_000
        val audio = audioMillis // real speech length; chunks may be silence-padded
        scheduleIdleRelease()
        Transcript(text, audio, decode, load, spec).also {
            Log.i(TAG, "decoded ${audio}ms audio in ${decode}ms (RTF %.3f), load ${load}ms, ${spec.kind}".format(it.rtf))
            PerfLog.add(PerfLog.Entry(System.currentTimeMillis(), spec.kind.name, audio, decode, load))
        }
    }

    fun release() {
        executor.execute { releaseNow() }
    }

    fun onTrimMemory(level: Int) {
        @Suppress("DEPRECATION")
        val severe = level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND
        if (severe || (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN && activeClients.get() == 0)) {
            Log.i(TAG, "onTrimMemory($level): releasing speech model")
            release()
        }
    }

    /** Returns load time in ms (0 if already loaded). Executor thread only. */
    private fun ensureLoaded(spec: EngineSpec): Long {
        idleRelease?.cancel(false)
        if (engine != null && loadedSpec == spec) {
            scheduleIdleRelease()
            return 0
        }
        releaseNow()
        val started = System.nanoTime()
        engine = factory(spec, modelsRoot)
        loadedSpec = spec
        lastLoadMillis = (System.nanoTime() - started) / 1_000_000
        Log.i(TAG, "loaded ${spec.kind} (${spec.language.ifEmpty { "auto" }}) in ${lastLoadMillis}ms")
        scheduleIdleRelease()
        return lastLoadMillis
    }

    private fun scheduleIdleRelease() {
        idleRelease?.cancel(false)
        idleRelease = executor.schedule({ releaseNow() }, idleReleaseMillis, TimeUnit.MILLISECONDS)
    }

    private fun releaseNow() {
        idleRelease?.cancel(false)
        idleRelease = null
        engine?.let {
            runCatching { it.close() }
            Log.i(TAG, "released ${loadedSpec?.kind}")
        }
        engine = null
        loadedSpec = null
    }

    companion object {
        private const val TAG = "SpeechEngineHost"
    }
}

/** Recent timing measurements for the debug screen (in memory only). */
object PerfLog {
    data class Entry(
        val timestamp: Long,
        val engine: String,
        val audioMillis: Long,
        val decodeMillis: Long,
        val loadMillis: Long,
        var polishMillis: Long = -1,
        var polishNote: String? = null,
    ) {
        val rtf: Double get() = if (audioMillis == 0L) 0.0 else decodeMillis.toDouble() / audioMillis
    }

    private val entries = ArrayDeque<Entry>()

    @Synchronized fun add(e: Entry) {
        entries.addFirst(e)
        while (entries.size > 30) entries.removeLast()
    }

    @Synchronized fun annotateLatest(polishMillis: Long, note: String?) {
        entries.firstOrNull()?.let { it.polishMillis = polishMillis; it.polishNote = note }
    }

    @Synchronized fun recent(): List<Entry> = entries.toList()
}

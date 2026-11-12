package dev.offline.voicetype.polish

import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.LogSeverity
import com.google.ai.edge.litertlm.SamplerConfig
import dev.offline.voicetype.cleanup.PolishRequest
import dev.offline.voicetype.cleanup.Polisher
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Stage 2 polish with a small instruction-tuned LLM (.litertlm file, e.g. Gemma 3 1B int4 or
 * Qwen2.5 1.5B) running fully on-device through LiteRT-LM. Loading takes a few seconds, so the
 * model is warmed up when the keyboard/bubble appears and released after 5 idle minutes.
 */
class LiteRtPolisher(
    private val modelFile: () -> File?,
    private val useGpu: () -> Boolean,
    private val cacheDir: File,
    private val threads: Int = 4,
    private val idleReleaseMillis: Long = 5 * 60_000L,
) : Polisher {

    private val lock = Any()
    private val loader = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "polish-loader") }
    private val loading = AtomicBoolean(false)
    private var idleRelease: ScheduledFuture<*>? = null

    @Volatile private var engine: Engine? = null
    @Volatile private var loadedKey: String? = null
    @Volatile private var current: Conversation? = null

    @Volatile var lastLoadMillis: Long = 0
        private set
    @Volatile var lastError: String? = null
        private set

    override val isReady: Boolean
        get() = engine != null && loadedKey == wantedKey()

    private fun wantedKey(): String? = modelFile()?.let { "${it.absolutePath}|${it.length()}|gpu=${useGpu()}" }

    override fun warmUp() {
        if (isReady) {
            scheduleIdleRelease()
            return
        }
        if (wantedKey() == null || !loading.compareAndSet(false, true)) return
        loader.execute {
            try {
                load()
            } catch (t: Throwable) {
                lastError = "${t.javaClass.simpleName}: ${t.message}"
                Log.w(TAG, "polish model failed to load", t)
            } finally {
                loading.set(false)
            }
        }
    }

    private fun load() {
        val file = modelFile() ?: return
        val key = wantedKey() ?: return
        synchronized(lock) {
            if (engine != null && loadedKey == key) return
            closeEngineLocked()
            Engine.setNativeMinLogSeverity(LogSeverity.ERROR)
            val started = System.nanoTime()
            val backend = if (useGpu()) Backend.GPU() else Backend.CPU(threadCount = threads)
            val e = Engine(
                EngineConfig(
                    modelPath = file.absolutePath,
                    backend = backend,
                    maxNumTokens = 1_024,
                    cacheDir = File(cacheDir, "litertlm").apply { mkdirs() }.absolutePath,
                ),
            )
            e.initialize()
            engine = e
            loadedKey = key
            lastError = null
            lastLoadMillis = (System.nanoTime() - started) / 1_000_000
            Log.i(TAG, "loaded ${file.name} (${if (useGpu()) "GPU" else "CPU x$threads"}) in ${lastLoadMillis}ms")
        }
        scheduleIdleRelease()
    }

    override fun polish(request: PolishRequest): String {
        synchronized(lock) {
            val e = engine ?: throw IllegalStateException("polish model not loaded")
            val conversation = e.createConversation(
                ConversationConfig(
                    systemInstruction = Contents.of(request.systemInstruction),
                    // topK = 1 -> greedy decoding: deterministic, no creative rewrites.
                    samplerConfig = SamplerConfig(topK = 1, topP = 1.0, temperature = 1.0),
                ),
            )
            current = conversation
            try {
                return conversation.sendMessage(request.userMessage, maxOutputToken = request.maxOutputTokens).toString()
            } finally {
                current = null
                runCatching { conversation.close() }
                scheduleIdleRelease()
            }
        }
    }

    /** Called from the pipeline thread when the 3 s budget is exceeded. */
    override fun cancel() {
        current?.let { runCatching { it.cancelProcess() } }
    }

    fun release() {
        cancel()
        loader.execute { synchronized(lock) { closeEngineLocked() } }
    }

    private fun scheduleIdleRelease() {
        idleRelease?.cancel(false)
        idleRelease = loader.schedule({ synchronized(lock) { closeEngineLocked() } }, idleReleaseMillis, TimeUnit.MILLISECONDS)
    }

    private fun closeEngineLocked() {
        engine?.let {
            runCatching { it.close() }
            Log.i(TAG, "released polish model")
        }
        engine = null
        loadedKey = null
    }

    companion object {
        private const val TAG = "LiteRtPolisher"
    }
}

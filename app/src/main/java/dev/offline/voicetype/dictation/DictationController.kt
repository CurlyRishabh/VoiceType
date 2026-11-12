package dev.offline.voicetype.dictation

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.offline.voicetype.app
import dev.offline.voicetype.cleanup.CleanupResult
import dev.offline.voicetype.engine.DictationRecorder
import dev.offline.voicetype.engine.EngineKind
import dev.offline.voicetype.engine.HallucinationFilter
import dev.offline.voicetype.engine.ModelSlot
import dev.offline.voicetype.engine.PerfLog
import dev.offline.voicetype.engine.WavWriter
import java.io.File
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors

/**
 * One dictation at a time: record -> VAD auto-stop -> speech-to-text -> Stage 1 (+ Stage 2) cleanup.
 * Callbacks arrive on the main thread. Audio exists only in memory and is wiped after decoding.
 */
class DictationController(context: Context, private val callback: Callback) {

    enum class State { IDLE, LISTENING, TRANSCRIBING, POLISHING }

    interface Callback {
        fun onState(state: State)
        fun onLevel(level: Float) {}
        fun onSpeechStarted() {}
        fun onResult(result: CleanupResult)
        fun onNoSpeech() {}
        fun onError(message: String)
    }

    /** Context of the field being typed into, captured when dictation starts. */
    data class Target(val startsSentence: Boolean, val endsSentence: Boolean, val plainText: Boolean)

    private val app = context.app
    private val main = Handler(Looper.getMainLooper())
    private var recorder: DictationRecorder? = null
    private var target = Target(true, true, true)
    @Volatile private var generation = 0

    var state: State = State.IDLE
        private set

    fun hasMicPermission(): Boolean =
        app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Returns false (and reports an error) if dictation cannot start. */
    fun start(target: Target, autoStop: Boolean = true): Boolean {
        if (state != State.IDLE) return false
        if (!hasMicPermission()) {
            callback.onError("Microphone permission needed. Open VoiceType to grant it.")
            return false
        }
        val spec = app.settings.engineSpec()
        val slot = if (spec.kind == EngineKind.FAST_ENGLISH) ModelSlot.MOONSHINE else ModelSlot.WHISPER
        if (!app.models.isReady(slot)) {
            callback.onError("${slot.title} isn't imported yet. Open VoiceType → Models.")
            return false
        }
        active?.takeIf { it !== this }?.cancel()
        active = this

        this.target = target
        app.warmUp()
        val gen = ++generation
        val rec = DictationRecorder(
            vadModel = app.models.vadFile(),
            config = DictationRecorder.Config(silenceMillis = app.settings.silenceMillis, autoStop = autoStop),
            listener = object : DictationRecorder.Listener {
                override fun onLevel(level: Float) {
                    main.post { if (gen == generation) callback.onLevel(level) }
                }

                override fun onSpeechStarted() {
                    main.post { if (gen == generation) callback.onSpeechStarted() }
                }

                override fun onAutoStopped(reason: DictationRecorder.StopReason) {
                    main.post { if (gen == generation && state == State.LISTENING) stop() }
                }
            },
        )
        recorder = rec
        rec.start()
        setState(State.LISTENING)
        return true
    }

    /** User (or auto-stop) ends recording; transcription starts. */
    fun stop() {
        val rec = recorder ?: return
        if (state != State.LISTENING) return
        recorder = null
        rec.requestStop()
        setState(State.TRANSCRIBING)
        val gen = generation
        val target = this.target
        worker.execute { process(rec, gen, target) }
    }

    /** Abandons the current dictation without inserting anything. */
    fun cancel() {
        generation++
        recorder?.abort()
        recorder = null
        if (active === this) active = null
        setState(State.IDLE)
    }

    private fun process(rec: DictationRecorder, gen: Int, target: Target) {
        val captured = rec.stop()
        try {
            captured.error?.let { throw it }
            if (gen != generation) return
            if (!captured.speechDetected || captured.pcm.isEmpty()) {
                post(gen) { setState(State.IDLE); callback.onNoSpeech() }
                return
            }
            if (captured.pcm.size > 16_000 && captured.pcm.all { it.toInt() == 0 }) {
                throw IllegalStateException("Android delivered silent audio — microphone access was blocked. Open VoiceType once, then try again.")
            }
            if (app.settings.keepRecordings) {
                runCatching { WavWriter.write(File(File(app.noBackupFilesDir, "recordings"), "rec-${System.currentTimeMillis()}.wav"), captured.pcm) }
            }

            val spec = app.settings.engineSpec()
            val chunks = captured.chunks(whisper = spec.kind == EngineKind.HINDI_ENGLISH, language = spec.language)
            val transcript = try {
                app.speech.transcribe(spec, chunks, captured.durationMillis).get()
            } catch (e: ExecutionException) {
                throw e.cause ?: e
            } finally {
                chunks.forEach { it.fill(0f) }
                captured.pcm.fill(0)
            }
            val raw = HallucinationFilter.clean(transcript.text, captured.speechMillis())
            if (gen != generation) return
            if (raw.isBlank()) {
                post(gen) { setState(State.IDLE); callback.onNoSpeech() }
                return
            }

            val settings = app.settings.cleanupSettings(
                startsSentence = target.startsSentence,
                endsSentence = target.endsSentence,
                plainText = target.plainText,
                polishAvailable = app.models.llmFile() != null,
            )
            if (settings.polishEnabled) post(gen) { setState(State.POLISHING) }
            val result = app.pipeline.process(raw, settings)
            PerfLog.annotateLatest(if (settings.polishEnabled) result.polishMillis else -1, result.fallbackReason)
            if (result.fallbackReason != null) Log.i(TAG, "polish fallback: ${result.fallbackReason}")

            if (app.settings.historyEnabled && result.text.isNotBlank()) {
                runCatching { app.history.add(result.text, raw, spec.kind.name, result.polished) }
            }
            post(gen) {
                setState(State.IDLE)
                if (result.text.isBlank()) callback.onNoSpeech() else callback.onResult(result)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "dictation failed", t)
            post(gen) {
                setState(State.IDLE)
                callback.onError(t.message ?: t.javaClass.simpleName)
            }
        } finally {
            captured.pcm.fill(0)
            if (active === this && gen == generation) active = null
        }
    }

    private fun post(gen: Int, block: () -> Unit) {
        main.post { if (gen == generation) block() }
    }

    private fun setState(s: State) {
        if (state == s) return
        state = s
        callback.onState(s)
    }

    companion object {
        private const val TAG = "Dictation"

        /** Decoding is serialised by SpeechEngineHost; this thread just waits on it. */
        private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "dictation-pipeline") }

        /** Only one dictation may hold the microphone. */
        @Volatile private var active: DictationController? = null
    }
}

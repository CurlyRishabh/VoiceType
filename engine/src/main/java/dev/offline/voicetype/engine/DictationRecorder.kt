package dev.offline.voicetype.engine

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import android.util.Log
import java.io.File
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Captures 16 kHz mono PCM16 from the VOICE_RECOGNITION source on a dedicated thread, runs Silero
 * VAD on it, and auto-stops after the configured trailing silence. Audio is held in memory only.
 */
class DictationRecorder(
    private val vadModel: File?,
    private val config: Config,
    private val listener: Listener,
) {

    data class Config(
        val silenceMillis: Int = 1_500,
        /** False for hold-to-talk: the user decides when to stop. */
        val autoStop: Boolean = true,
        val noSpeechTimeoutMillis: Int = 8_000,
        val maxDurationMillis: Int = 5 * 60_000,
    )

    enum class StopReason { USER, SILENCE, NO_SPEECH, MAX_DURATION, ERROR }

    interface Listener {
        /** 0..1 input level, ~15 times per second. Called on the capture thread. */
        fun onLevel(level: Float) {}
        fun onSpeechStarted() {}
        /** Recording ended on its own (silence, timeout, error). Called on the capture thread. */
        fun onAutoStopped(reason: StopReason) {}
    }

    class Captured(
        val pcm: ShortArray,
        /** VAD segments, or null when no VAD model is available. */
        val segments: List<Segment>?,
        val speechDetected: Boolean,
        val stopReason: StopReason,
        val error: Throwable?,
    ) {
        val durationMillis: Long get() = pcm.size * 1000L / SAMPLE_RATE

        fun speechMillis(): Long = segments?.sumOf { it.length }?.let { it * 1000 / SAMPLE_RATE } ?: durationMillis

        /** Float chunks ready for the recogniser (see [AudioChunker.chunks]). */
        fun chunks(whisper: Boolean = false, language: String = "en"): List<FloatArray> =
            AudioChunker.chunks(pcm, segments, whisper, language)
    }

    @Volatile private var stopRequested = false
    @Volatile private var aborted = false
    @Volatile private var stopReason = StopReason.USER
    @Volatile private var error: Throwable? = null
    private var thread: Thread? = null

    private val pcm = PcmBuffer()
    private val segments = ArrayList<Segment>()
    @Volatile private var speechSeen = false
    private var vadAvailable = false

    fun start() {
        check(thread == null) { "already started" }
        thread = Thread(::run, "dictation-capture").apply { start() }
    }

    /** Stops recording (if still running) and returns what was captured. */
    fun stop(): Captured {
        stopRequested = true
        val t = thread
        if (t != null && t !== Thread.currentThread()) t.join(2_000)
        return Captured(
            pcm = pcm.toArray(),
            segments = if (vadAvailable) synchronized(segments) { segments.toList() } else null,
            speechDetected = speechSeen || !vadAvailable,
            stopReason = stopReason,
            error = error,
        )
    }

    /** Non-blocking: asks the capture thread to stop; collect the audio later with [stop]. */
    fun requestStop() {
        stopRequested = true
    }

    /** Non-blocking: stops capture and wipes the audio. */
    fun abort() {
        aborted = true
        stopRequested = true
        if (thread?.isAlive != true) pcm.clear()
    }

    @SuppressLint("MissingPermission") // checked by callers; SecurityException is handled below
    private fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        var record: AudioRecord? = null
        var vad: VoiceActivityDetector? = null
        try {
            vad = vadModel?.takeIf { it.isFile }?.let { runCatching { VoiceActivityDetector(it) }.getOrNull() }
            vadAvailable = vad != null

            val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            record = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, SAMPLE_RATE * 2 / 5), // >= 200 ms
            )
            check(record.state == AudioRecord.STATE_INITIALIZED) { "Microphone unavailable (is another app recording?)" }
            record.startRecording()

            val shorts = ShortArray(FRAME)
            val floats = FloatArray(FRAME)
            var silentSamples = 0L
            var frames = 0
            val hangoverMs = (VoiceActivityDetector.MIN_SILENCE_SEC * 1000).toInt()

            while (!stopRequested) {
                val n = record.read(shorts, 0, FRAME)
                if (n < 0) error("AudioRecord.read failed: $n")
                if (n == 0) continue
                pcm.append(shorts, n)

                var sumSq = 0.0
                for (i in 0 until n) {
                    val f = shorts[i] / 32768f
                    floats[i] = f
                    sumSq += f * f
                }
                if (frames++ % 2 == 0) listener.onLevel(levelOf(sqrt(sumSq / n)))

                if (vad != null) {
                    vad.accept(floats, n)
                    val speech = vad.isSpeech()
                    if (speech) {
                        if (!speechSeen) {
                            speechSeen = true
                            listener.onSpeechStarted()
                        }
                        silentSamples = 0
                    } else if (speechSeen) {
                        silentSamples += n
                    }
                    val done = vad.drainSegments()
                    if (done.isNotEmpty()) synchronized(segments) { segments += done }

                    if (config.autoStop) {
                        val silentMs = silentSamples * 1000 / SAMPLE_RATE + hangoverMs
                        if (speechSeen && !speech && silentMs >= config.silenceMillis) {
                            stopReason = StopReason.SILENCE
                            break
                        }
                        if (!speechSeen && pcm.size * 1000L / SAMPLE_RATE >= config.noSpeechTimeoutMillis) {
                            stopReason = StopReason.NO_SPEECH
                            break
                        }
                    }
                }
                if (pcm.size * 1000L / SAMPLE_RATE >= config.maxDurationMillis) {
                    stopReason = StopReason.MAX_DURATION
                    break
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "capture failed", t)
            error = t
            stopReason = StopReason.ERROR
        } finally {
            runCatching { record?.stop() }
            runCatching { record?.release() }
            if (vad != null) {
                runCatching {
                    vad.flush()
                    val rest = vad.drainSegments()
                    synchronized(segments) { segments += rest }
                    if (rest.isNotEmpty()) speechSeen = true
                }
                runCatching { vad.close() }
            }
            if (aborted) pcm.clear()
        }
        if (!aborted && (!stopRequested || stopReason != StopReason.USER)) listener.onAutoStopped(stopReason)
    }

    private fun levelOf(rms: Double): Float {
        if (rms <= 1e-9) return 0f
        val db = 20 * log10(rms)
        return ((db + 55) / 50).toFloat().coerceIn(0f, 1f)
    }

    /** Growable PCM16 buffer; avoids boxing for minutes of audio. */
    private class PcmBuffer {
        private var data = ShortArray(SAMPLE_RATE * 10)
        @Volatile var size = 0
            private set

        @Synchronized fun append(src: ShortArray, n: Int) {
            if (size + n > data.size) data = data.copyOf(maxOf(data.size * 2, size + n))
            System.arraycopy(src, 0, data, size, n)
            size += n
        }

        @Synchronized fun toArray(): ShortArray = data.copyOf(size)

        @Synchronized fun clear() {
            data.fill(0)
            size = 0
        }
    }

    companion object {
        private const val TAG = "DictationRecorder"
        private const val FRAME = 512 // 32 ms
    }
}

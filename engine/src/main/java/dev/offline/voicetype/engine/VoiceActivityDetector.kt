package dev.offline.voicetype.engine

import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.Closeable
import java.io.File

/** Silero VAD (via sherpa-onnx). Single-threaded: used only from the capture thread. */
class VoiceActivityDetector(model: File) : Closeable {

    private val vad = Vad(
        assetManager = null,
        config = VadModelConfig(
            sileroVadModelConfig = SileroVadModelConfig(
                model = model.absolutePath,
                threshold = 0.45f,
                minSilenceDuration = MIN_SILENCE_SEC,
                minSpeechDuration = 0.20f,
                windowSize = WINDOW,
                maxSpeechDuration = 8f, // short segments: Whisper token budget + natural split points
            ),
            sampleRate = SAMPLE_RATE,
            numThreads = 1,
            provider = "cpu",
        ),
    )

    private val window = FloatArray(WINDOW)
    private var filled = 0

    /** Feeds any number of samples; the VAD sees them in exact 512-sample windows. */
    fun accept(samples: FloatArray, count: Int = samples.size) {
        var i = 0
        while (i < count) {
            val n = minOf(WINDOW - filled, count - i)
            System.arraycopy(samples, i, window, filled, n)
            filled += n
            i += n
            if (filled == WINDOW) {
                vad.acceptWaveform(window.copyOf())
                filled = 0
            }
        }
    }

    /** True while inside a speech segment (including Silero's [MIN_SILENCE_SEC] hangover). */
    fun isSpeech(): Boolean = vad.isSpeechDetected()

    /** Removes and returns the finished speech segments as (startSample, lengthSamples). */
    fun drainSegments(): List<Segment> {
        val out = ArrayList<Segment>()
        while (!vad.empty()) {
            val s = vad.front()
            out += Segment(s.start, s.samples.size.toLong())
            vad.pop()
        }
        return out
    }

    fun flush() = vad.flush()

    override fun close() = vad.release()

    companion object {
        const val WINDOW = 512
        const val MIN_SILENCE_SEC = 0.5f
    }
}

data class Segment(val start: Long, val length: Long) {
    val end: Long get() = start + length
}

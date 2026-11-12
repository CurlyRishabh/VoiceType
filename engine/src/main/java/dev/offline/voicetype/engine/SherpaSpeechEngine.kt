package dev.offline.voicetype.engine

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import java.io.File

/** sherpa-onnx offline recogniser running Moonshine (English) or Whisper (multilingual). */
class SherpaSpeechEngine private constructor(
    override val spec: EngineSpec,
    private val recognizer: OfflineRecognizer,
) : SpeechEngine {

    override fun transcribe(samples: FloatArray, sampleRate: Int): String {
        if (samples.isEmpty()) return ""
        val stream = recognizer.createStream()
        try {
            stream.acceptWaveform(samples, sampleRate)
            recognizer.decode(stream)
            return recognizer.getResult(stream).text.trim()
        } finally {
            stream.release()
        }
    }

    override fun close() = recognizer.release()

    companion object {
        /** Throws [IllegalStateException] with a user-readable message if model files are missing. */
        fun create(spec: EngineSpec, modelsRoot: File): SherpaSpeechEngine {
            val modelConfig = when (spec.kind) {
                EngineKind.FAST_ENGLISH -> moonshineConfig(spec, modelsRoot)
                EngineKind.HINDI_ENGLISH -> whisperConfig(spec, modelsRoot)
            }
            val config = OfflineRecognizerConfig(
                featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                modelConfig = modelConfig,
                decodingMethod = "greedy_search",
            )
            return SherpaSpeechEngine(spec, OfflineRecognizer(assetManager = null, config = config))
        }

        private fun moonshineConfig(spec: EngineSpec, root: File): OfflineModelConfig {
            val files = ModelLayout.findMoonshine(ModelLayout.slotDir(root, ModelSlot.MOONSHINE))
                ?: error("Fast English model not imported. Expected: ${ModelLayout.expectedFiles(ModelSlot.MOONSHINE)}")
            val moonshine = when (files) {
                is SpeechModelFiles.MoonshineV1 -> OfflineMoonshineModelConfig(
                    preprocessor = files.preprocessor.absolutePath,
                    encoder = files.encoder.absolutePath,
                    uncachedDecoder = files.uncachedDecoder.absolutePath,
                    cachedDecoder = files.cachedDecoder.absolutePath,
                )
                is SpeechModelFiles.MoonshineV2 -> OfflineMoonshineModelConfig(
                    encoder = files.encoder.absolutePath,
                    mergedDecoder = files.mergedDecoder.absolutePath,
                )
                is SpeechModelFiles.Whisper -> error("unreachable")
            }
            return OfflineModelConfig(
                moonshine = moonshine,
                tokens = files.tokens.absolutePath,
                numThreads = spec.threads,
                provider = "cpu",
            )
        }

        private fun whisperConfig(spec: EngineSpec, root: File): OfflineModelConfig {
            val files = ModelLayout.findWhisper(ModelLayout.slotDir(root, ModelSlot.WHISPER))
                ?: error("Hindi + English model not imported. Expected: ${ModelLayout.expectedFiles(ModelSlot.WHISPER)}")
            return OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = files.encoder.absolutePath,
                    decoder = files.decoder.absolutePath,
                    language = spec.language, // "" = auto-detect
                    task = "transcribe",      // never "translate"
                ),
                tokens = files.tokens.absolutePath,
                modelType = "whisper",
                numThreads = spec.threads,
                provider = "cpu",
            )
        }
    }
}

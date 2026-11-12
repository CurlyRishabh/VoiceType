package dev.offline.voicetype.engine

import java.io.File

/**
 * Where imported models live (app-private, excluded from backup) and how their files are
 * recognised. Pure java.io so it can be unit tested on the JVM.
 */
enum class ModelSlot(val dirName: String, val title: String) {
    MOONSHINE("moonshine-base-en", "Fast English (Moonshine Base, int8)"),
    WHISPER("whisper-small", "Hindi + English (Whisper small, int8)"),
    VAD("silero-vad", "Silero VAD"),
    LLM("polish-llm", "AI polish model (.litertlm)"),
}

sealed class SpeechModelFiles {
    abstract val tokens: File

    data class MoonshineV1(
        val preprocessor: File, val encoder: File, val uncachedDecoder: File, val cachedDecoder: File,
        override val tokens: File,
    ) : SpeechModelFiles()

    data class MoonshineV2(val encoder: File, val mergedDecoder: File, override val tokens: File) : SpeechModelFiles()

    data class Whisper(val encoder: File, val decoder: File, override val tokens: File) : SpeechModelFiles()
}

object ModelLayout {

    fun slotDir(modelsRoot: File, slot: ModelSlot): File = File(modelsRoot, slot.dirName)

    /** Which imported file names belong in which slot (used to validate the user's picks). */
    fun accepts(slot: ModelSlot, fileName: String): Boolean {
        val n = fileName.lowercase()
        return when (slot) {
            ModelSlot.MOONSHINE -> n.endsWith(".onnx") || n.endsWith(".ort") || n == "tokens.txt"
            ModelSlot.WHISPER -> n.endsWith(".onnx") || n.endsWith("tokens.txt")
            ModelSlot.VAD -> n.endsWith(".onnx")
            ModelSlot.LLM -> n.endsWith(".litertlm")
        }
    }

    fun findMoonshine(dir: File): SpeechModelFiles? {
        val files = dir.listFiles()?.filter { it.isFile } ?: return null
        val tokens = files.firstOrNull { it.name == "tokens.txt" } ?: return null
        // v2 (2026 "quantized" release): encoder + merged decoder
        val v2Encoder = files.firstOrNull { it.name.startsWith("encoder_model") }
        val v2Decoder = files.firstOrNull { it.name.startsWith("decoder_model_merged") }
        if (v2Encoder != null && v2Decoder != null) return SpeechModelFiles.MoonshineV2(v2Encoder, v2Decoder, tokens)
        // v1 (int8 release): preprocess + encode + uncached/cached decoders
        val pre = files.firstOrNull { it.name.startsWith("preprocess") } ?: return null
        val enc = preferInt8(files.filter { it.name.startsWith("encode") }) ?: return null
        val unc = preferInt8(files.filter { it.name.startsWith("uncached_decode") }) ?: return null
        val cac = preferInt8(files.filter { it.name.startsWith("cached_decode") }) ?: return null
        return SpeechModelFiles.MoonshineV1(pre, enc, unc, cac, tokens)
    }

    fun findWhisper(dir: File): SpeechModelFiles.Whisper? {
        val files = dir.listFiles()?.filter { it.isFile } ?: return null
        val enc = preferInt8(files.filter { it.name.contains("encoder") && it.name.endsWith(".onnx") }) ?: return null
        val dec = preferInt8(files.filter { it.name.contains("decoder") && it.name.endsWith(".onnx") }) ?: return null
        val tokens = files.firstOrNull { it.name.endsWith("tokens.txt") } ?: return null
        return SpeechModelFiles.Whisper(enc, dec, tokens)
    }

    fun findVad(dir: File): File? =
        dir.listFiles()?.firstOrNull { it.isFile && it.name.endsWith(".onnx") }

    fun findLlm(dir: File): File? =
        dir.listFiles()?.filter { it.isFile && it.name.endsWith(".litertlm") }?.maxByOrNull { it.lastModified() }

    fun isComplete(modelsRoot: File, slot: ModelSlot): Boolean {
        val dir = slotDir(modelsRoot, slot)
        return when (slot) {
            ModelSlot.MOONSHINE -> findMoonshine(dir) != null
            ModelSlot.WHISPER -> findWhisper(dir) != null
            ModelSlot.VAD -> findVad(dir) != null
            ModelSlot.LLM -> findLlm(dir) != null
        }
    }

    /** Human-readable list of what a slot still needs. */
    fun expectedFiles(slot: ModelSlot): String = when (slot) {
        ModelSlot.MOONSHINE ->
            "tokens.txt plus either preprocess.onnx, encode.int8.onnx, uncached_decode.int8.onnx, cached_decode.int8.onnx " +
                "or encoder_model.ort and decoder_model_merged.ort"
        ModelSlot.WHISPER -> "small-encoder.int8.onnx, small-decoder.int8.onnx, small-tokens.txt"
        ModelSlot.VAD -> "silero_vad.onnx"
        ModelSlot.LLM -> "one .litertlm file (e.g. gemma3-1b-it-int4.litertlm)"
    }

    private fun preferInt8(candidates: List<File>): File? =
        candidates.firstOrNull { it.name.contains("int8") } ?: candidates.firstOrNull()
}

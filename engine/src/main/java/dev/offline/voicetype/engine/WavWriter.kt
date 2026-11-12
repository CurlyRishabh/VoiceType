package dev.offline.voicetype.engine

import java.io.DataInputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Minimal 16-bit mono WAV I/O for the off-by-default "keep recordings" debug option. */
object WavWriter {

    fun write(file: File, pcm: ShortArray, sampleRate: Int = SAMPLE_RATE) {
        val dataBytes = pcm.size * 2
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + dataBytes); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)
            putInt(sampleRate); putInt(sampleRate * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(dataBytes)
        }
        val body = ByteBuffer.allocate(dataBytes).order(ByteOrder.LITTLE_ENDIAN)
        body.asShortBuffer().put(pcm)
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { it.write(header.array()); it.write(body.array()) }
    }

    /** Reads back a file written by [write]. */
    fun read(file: File): ShortArray {
        DataInputStream(file.inputStream().buffered()).use { input ->
            val all = input.readBytes()
            require(all.size >= 44) { "not a WAV file" }
            val bb = ByteBuffer.wrap(all, 44, all.size - 44).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            return ShortArray(bb.remaining()).also { bb.get(it) }
        }
    }
}

package dev.offline.voicetype.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import dev.offline.voicetype.engine.ModelLayout
import dev.offline.voicetype.engine.ModelSlot
import java.io.File
import java.io.IOException

/**
 * Model files imported from local storage through the system file picker (ACTION_OPEN_DOCUMENT).
 * The app never downloads anything. Files are copied into app-private, no-backup storage.
 */
class ModelStore(private val context: Context) {

    val root: File = File(context.noBackupFilesDir, "models").apply { mkdirs() }

    fun dir(slot: ModelSlot): File = ModelLayout.slotDir(root, slot).apply { mkdirs() }

    fun isReady(slot: ModelSlot): Boolean = ModelLayout.isComplete(root, slot)

    fun vadFile(): File? = ModelLayout.findVad(dir(ModelSlot.VAD))

    fun llmFile(): File? = ModelLayout.findLlm(dir(ModelSlot.LLM))

    fun files(slot: ModelSlot): List<File> = dir(slot).listFiles()?.filter { it.isFile && !it.name.endsWith(".part") }?.sortedBy { it.name } ?: emptyList()

    fun sizeBytes(slot: ModelSlot): Long = files(slot).sumOf { it.length() }

    fun clear(slot: ModelSlot) {
        dir(slot).listFiles()?.forEach { it.delete() }
    }

    data class ImportResult(val imported: List<String>, val skipped: List<String>, val error: String?)

    /**
     * Copies the picked files into [slot]. Blocking: call off the main thread.
     * [progress] receives (bytesCopied, totalBytes, currentFileName).
     */
    fun import(slot: ModelSlot, uris: List<Uri>, progress: (Long, Long, String) -> Unit): ImportResult {
        val resolver = context.contentResolver
        data class Pick(val uri: Uri, val name: String, val size: Long)

        val picks = uris.map { uri ->
            var name = uri.lastPathSegment ?: "file"
            var size = -1L
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
            Pick(uri, sanitize(name), size)
        }
        val (accepted, rejected) = picks.partition { ModelLayout.accepts(slot, it.name) }
        if (accepted.isEmpty()) {
            return ImportResult(emptyList(), rejected.map { it.name }, "None of the selected files belong here. Expected: ${ModelLayout.expectedFiles(slot)}")
        }

        val total = accepted.sumOf { maxOf(it.size, 0) }
        val target = dir(slot)
        if (total > 0 && target.usableSpace < total + 200L * 1024 * 1024) {
            return ImportResult(emptyList(), rejected.map { it.name }, "Not enough free storage: need ${total / 1_048_576} MB")
        }
        // The polish slot holds exactly one model.
        if (slot == ModelSlot.LLM) clear(slot)

        var copied = 0L
        val done = ArrayList<String>()
        try {
            for (p in accepted) {
                val part = File(target, p.name + ".part")
                resolver.openInputStream(p.uri).use { input ->
                    input ?: throw IOException("Cannot open ${p.name}")
                    part.outputStream().use { out ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            copied += n
                            progress(copied, total, p.name)
                        }
                    }
                }
                val dest = File(target, p.name)
                dest.delete()
                if (!part.renameTo(dest)) throw IOException("Could not save ${p.name}")
                done += p.name
            }
        } catch (e: Exception) {
            target.listFiles()?.filter { it.name.endsWith(".part") }?.forEach { it.delete() }
            return ImportResult(done, rejected.map { it.name }, e.message ?: e.javaClass.simpleName)
        }
        return ImportResult(done, rejected.map { it.name }, null)
    }

    private fun sanitize(name: String): String =
        name.substringAfterLast('/').replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "file" }
}

package dev.offline.voicetype.ui

import android.net.Uri
import android.os.Bundle
import android.text.format.Formatter
import android.view.View
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.engine.ModelLayout
import dev.offline.voicetype.engine.ModelSlot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Imports model files the user copied to the phone, using the system file picker only. */
class ModelsActivity : AppCompatActivity() {

    private lateinit var adapter: SimpleListAdapter<ModelSlot>
    private var pendingSlot: ModelSlot? = null

    // ACTION_OPEN_DOCUMENT with multi-select: the user grants access to exactly the chosen files.
    private val picker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val slot = pendingSlot ?: return@registerForActivityResult
        pendingSlot = null
        if (uris.isNotEmpty()) import(slot, uris)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_list)
        findViewById<TextView>(R.id.intro).apply {
            setText(R.string.models_intro)
            visibility = View.VISIBLE
        }
        adapter = SimpleListAdapter(bind = ::row)
        findViewById<RecyclerView>(R.id.list).apply {
            layoutManager = LinearLayoutManager(this@ModelsActivity)
            adapter = this@ModelsActivity.adapter
        }
        adapter.items = ModelSlot.entries
    }

    private fun row(slot: ModelSlot): SimpleListAdapter.Row {
        val models = app.models
        val ready = models.isReady(slot)
        val need = when (slot) {
            ModelSlot.VAD -> getString(R.string.models_required)
            ModelSlot.MOONSHINE, ModelSlot.WHISPER -> "At least one speech model required"
            ModelSlot.LLM -> getString(R.string.models_optional)
        }
        val status = if (ready) {
            getString(R.string.models_ready, Formatter.formatShortFileSize(this, models.sizeBytes(slot)))
        } else {
            getString(R.string.models_missing, ModelLayout.expectedFiles(slot))
        }
        val files = models.files(slot).joinToString { it.name }
        return SimpleListAdapter.Row(
            line1 = slot.title,
            line2 = "$need\n$status" + if (files.isNotEmpty()) "\n$files" else "",
            buttons = buildList {
                add(getString(R.string.models_import) to { pendingSlot = slot; picker.launch(arrayOf("*/*")) })
                if (models.files(slot).isNotEmpty()) add(getString(R.string.models_delete) to { confirmDelete(slot) })
            },
        )
    }

    private fun import(slot: ModelSlot, uris: List<Uri>) {
        val bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 1000; setPadding(48, 24, 48, 24) }
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.models_importing, slot.title))
            .setView(bar)
            .setCancelable(false)
            .show()
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                app.models.import(slot, uris) { copied, total, _ ->
                    if (total > 0) bar.post { bar.progress = (copied * 1000 / total).toInt() }
                }
            }
            dialog.dismiss()
            if (slot == ModelSlot.LLM) app.polisher.release()
            app.speech.release() // next dictation loads the new files
            val msg = buildString {
                if (result.imported.isNotEmpty()) append("Imported: ${result.imported.joinToString()}\n")
                if (result.skipped.isNotEmpty()) append("Skipped (not for this model): ${result.skipped.joinToString()}\n")
                result.error?.let { append("Error: $it\n") }
                if (!app.models.isReady(slot)) append("\nStill needed: ${ModelLayout.expectedFiles(slot)}")
            }
            AlertDialog.Builder(this@ModelsActivity).setTitle(slot.title).setMessage(msg.trim()).setPositiveButton(R.string.ok, null).show()
            adapter.items = ModelSlot.entries
            app.warmUp()
        }
    }

    private fun confirmDelete(slot: ModelSlot) {
        AlertDialog.Builder(this)
            .setTitle(slot.title)
            .setMessage("Delete these model files from the phone?")
            .setPositiveButton(R.string.delete) { _, _ ->
                if (slot == ModelSlot.LLM) app.polisher.release()
                app.speech.release()
                app.models.clear(slot)
                adapter.items = ModelSlot.entries
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }
}

package dev.offline.voicetype.ui

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.cleanup.PersonalDictionary

/** Personal dictionary: "when I say X, write Y" (applied after every other rule and after AI polish). */
class DictionaryActivity : AppCompatActivity() {

    private lateinit var adapter: SimpleListAdapter<PersonalDictionary.Entry>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_list)
        adapter = SimpleListAdapter(
            bind = { SimpleListAdapter.Row("${it.from}  →  ${it.to}", null) },
            onClick = ::edit,
            onLongClick = ::confirmDelete,
        )
        findViewById<RecyclerView>(R.id.list).apply {
            layoutManager = LinearLayoutManager(this@DictionaryActivity)
            adapter = this@DictionaryActivity.adapter
        }
        findViewById<TextView>(R.id.empty).setText(R.string.dictionary_empty)
        findViewById<Button>(R.id.action).apply {
            setText(R.string.dictionary_add)
            visibility = View.VISIBLE
            setOnClickListener { edit(null) }
        }
        reload()
    }

    private fun reload() {
        adapter.items = app.settings.dictionary.entries.sortedBy { it.from.lowercase() }
        findViewById<TextView>(R.id.empty).visibility = if (adapter.items.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun edit(entry: PersonalDictionary.Entry?) {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val from = EditText(this).apply { setHint(R.string.dictionary_from); setText(entry?.from); isSingleLine = true }
        val to = EditText(this).apply { setHint(R.string.dictionary_to); setText(entry?.to); isSingleLine = true }
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
            addView(from)
            addView(to)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.dictionary_add)
            .setView(form)
            .setPositiveButton(R.string.ok) { _, _ ->
                val f = from.text.toString().trim()
                val t = to.text.toString().trim()
                if (f.isNotEmpty() && t.isNotEmpty()) {
                    var dict = app.settings.dictionary
                    if (entry != null) dict = dict.minus(entry.from)
                    app.settings.dictionary = dict.plus(PersonalDictionary.Entry(f, t))
                    reload()
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun confirmDelete(entry: PersonalDictionary.Entry) {
        AlertDialog.Builder(this)
            .setMessage(R.string.dictionary_delete_q)
            .setPositiveButton(R.string.delete) { _, _ ->
                app.settings.dictionary = app.settings.dictionary.minus(entry.from)
                reload()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }
}

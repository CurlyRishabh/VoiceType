package dev.offline.voicetype.ui

import android.os.Bundle
import android.text.format.DateUtils
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.data.HistoryStore
import dev.offline.voicetype.insertion.TextInserter

/** Local transcript history. Tap to copy, long-press to delete, one tap to clear everything. */
class HistoryActivity : AppCompatActivity() {

    private lateinit var adapter: SimpleListAdapter<HistoryStore.Item>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_list)
        adapter = SimpleListAdapter(
            bind = { item ->
                val whenText = DateUtils.getRelativeTimeSpanString(item.timestamp)
                val meta = "$whenText · ${if (item.engine == "FAST_ENGLISH") "Fast English" else "Hindi + English"}" +
                    (if (item.polished) " · AI polished" else "") +
                    (if (item.raw != item.text) "\nheard: ${item.raw}" else "")
                SimpleListAdapter.Row(item.text, meta)
            },
            onClick = { item ->
                TextInserter.copyToClipboard(this, item.text)
                Toast.makeText(this, R.string.history_copied, Toast.LENGTH_SHORT).show()
            },
            onLongClick = { item ->
                app.history.delete(item.id)
                reload()
            },
        )
        findViewById<RecyclerView>(R.id.list).apply {
            layoutManager = LinearLayoutManager(this@HistoryActivity)
            adapter = this@HistoryActivity.adapter
        }
        findViewById<TextView>(R.id.empty).setText(R.string.history_empty)
        findViewById<Button>(R.id.action).apply {
            setText(R.string.history_clear)
            visibility = View.VISIBLE
            setOnClickListener {
                app.history.clearAll()
                reload()
                Toast.makeText(this@HistoryActivity, R.string.history_cleared, Toast.LENGTH_SHORT).show()
            }
        }
        reload()
    }

    private fun reload() {
        adapter.items = app.history.list()
        findViewById<TextView>(R.id.empty).visibility = if (adapter.items.isEmpty()) View.VISIBLE else View.GONE
    }
}

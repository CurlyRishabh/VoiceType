package dev.offline.voicetype.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import dev.offline.voicetype.R

/** Two-line rows with optional buttons; enough for models, dictionary, history and debug lists. */
class SimpleListAdapter<T>(
    private val bind: (T) -> Row,
    private val onClick: ((T) -> Unit)? = null,
    private val onLongClick: ((T) -> Unit)? = null,
) : RecyclerView.Adapter<SimpleListAdapter.Holder>() {

    data class Row(val line1: CharSequence, val line2: CharSequence?, val buttons: List<Pair<String, () -> Unit>> = emptyList())

    class Holder(view: View) : RecyclerView.ViewHolder(view) {
        val line1: TextView = view.findViewById(R.id.line1)
        val line2: TextView = view.findViewById(R.id.line2)
        val buttons: LinearLayout = view.findViewById(R.id.buttons)
    }

    var items: List<T> = emptyList()
        set(value) {
            field = value
            @Suppress("NotifyDataSetChanged") notifyDataSetChanged()
        }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
        Holder(LayoutInflater.from(parent.context).inflate(R.layout.item_two_line, parent, false))

    override fun getItemCount() = items.size

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val item = items[position]
        val row = bind(item)
        holder.line1.text = row.line1
        holder.line2.text = row.line2
        holder.line2.visibility = if (row.line2.isNullOrEmpty()) View.GONE else View.VISIBLE
        holder.buttons.removeAllViews()
        holder.buttons.visibility = if (row.buttons.isEmpty()) View.GONE else View.VISIBLE
        for ((label, action) in row.buttons) {
            holder.buttons.addView(
                MaterialButton(holder.itemView.context, null, androidx.appcompat.R.attr.borderlessButtonStyle).apply {
                    text = label
                    setOnClickListener { action() }
                },
            )
        }
        holder.itemView.setOnClickListener(onClick?.let { c -> View.OnClickListener { c(item) } })
        holder.itemView.setOnLongClickListener(onLongClick?.let { c -> View.OnLongClickListener { c(item); true } })
    }
}

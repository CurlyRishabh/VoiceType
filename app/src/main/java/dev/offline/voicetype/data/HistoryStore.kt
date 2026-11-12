package dev.offline.voicetype.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Local-only transcript history (SQLite in app-private storage, excluded from backup). */
class HistoryStore(context: Context) : SQLiteOpenHelper(context, "history.db", null, 1) {

    data class Item(val id: Long, val timestamp: Long, val text: String, val raw: String, val engine: String, val polished: Boolean)

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE history (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, " +
                "text TEXT NOT NULL, raw TEXT NOT NULL, engine TEXT NOT NULL, polished INTEGER NOT NULL)",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    fun add(text: String, raw: String, engine: String, polished: Boolean) {
        writableDatabase.apply {
            insert("history", null, ContentValues().apply {
                put("ts", System.currentTimeMillis())
                put("text", text)
                put("raw", raw)
                put("engine", engine)
                put("polished", if (polished) 1 else 0)
            })
            execSQL("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT $MAX_ITEMS)")
        }
    }

    fun list(): List<Item> = readableDatabase.query(
        "history", arrayOf("id", "ts", "text", "raw", "engine", "polished"), null, null, null, null, "id DESC", "$MAX_ITEMS",
    ).use { c ->
        buildList {
            while (c.moveToNext()) add(Item(c.getLong(0), c.getLong(1), c.getString(2), c.getString(3), c.getString(4), c.getInt(5) == 1))
        }
    }

    fun delete(id: Long) {
        writableDatabase.delete("history", "id = ?", arrayOf(id.toString()))
    }

    fun clearAll() {
        writableDatabase.apply {
            delete("history", null, null)
            execSQL("VACUUM") // don't leave deleted transcripts in free pages
        }
    }

    companion object {
        const val MAX_ITEMS = 500
    }
}

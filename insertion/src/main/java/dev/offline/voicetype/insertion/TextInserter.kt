package dev.offline.voicetype.insertion

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.accessibility.AccessibilityNodeInfo
import dev.offline.voicetype.cleanup.TextJoin

/**
 * Inserts dictated text into whatever field has input focus, via [InsertionAccessibilityService].
 *
 * Preferred path: ACTION_SET_TEXT with (existing text + dictation spliced in at the cursor), then
 * ACTION_SET_SELECTION to put the cursor after it. That path is only used where it is safe: not for
 * password fields, WebViews/browsers (their exposed text can be partial), very long fields, or
 * fields whose text the app hides. Everything else uses the paste fallback, which temporarily puts
 * the text on the clipboard and then restores the user's previous clip.
 *
 * Call on the main thread.
 */
object TextInserter {

    enum class Outcome { SET_TEXT, PASTED, NO_SERVICE, NO_FOCUSED_FIELD, FAILED }

    /** Text around the cursor of the focused field, used to decide capitalisation/spacing. */
    data class FieldContext(val before: String?, val after: String?)

    private const val MAX_SET_TEXT_LENGTH = 5_000
    private const val CLIP_RESTORE_DELAY_MS = 600L

    private val main = Handler(Looper.getMainLooper())

    fun isAvailable(): Boolean = InsertionAccessibilityService.isRunning()

    fun focusedFieldContext(): FieldContext? {
        val node = focusedEditable() ?: return null
        if (node.isPassword) return FieldContext(null, null)
        val text = currentText(node) ?: return FieldContext(null, null)
        val (start, end) = selection(node, text.length)
        return FieldContext(text.substring(0, start), text.substring(end))
    }

    fun insert(context: Context, text: String): Outcome {
        if (text.isEmpty()) return Outcome.FAILED
        if (!isAvailable()) return Outcome.NO_SERVICE
        val node = focusedEditable() ?: return Outcome.NO_FOCUSED_FIELD

        val current = currentText(node)
        if (current != null && isSafeForSetText(node, current)) {
            val (start, end) = selection(node, current.length)
            val merged = TextJoin.merge(current, start, end, text)
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, merged.text)
            }
            if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                node.refresh()
                val cursor = merged.cursor.coerceAtMost(node.text?.length ?: merged.cursor)
                node.performAction(
                    AccessibilityNodeInfo.ACTION_SET_SELECTION,
                    Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
                    },
                )
                return Outcome.SET_TEXT
            }
        }

        // Paste fallback: add spacing from whatever context we can see.
        val padded = if (current != null && !node.isPassword) {
            val (start, end) = selection(node, current.length)
            TextJoin.pad(text, current.substring(0, start), current.substring(end))
        } else {
            text
        }
        return if (pasteViaClipboard(context, node, padded)) Outcome.PASTED else Outcome.FAILED
    }

    /** Puts [text] on the clipboard (marked sensitive) without pasting — last-resort fallback. */
    fun copyToClipboard(context: Context, text: String) {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return
        cm.setPrimaryClip(sensitiveClip(text))
    }

    // ------------------------------------------------------------------ internals

    private fun focusedEditable(): AccessibilityNodeInfo? {
        val svc = InsertionAccessibilityService.instance ?: return null
        val node = svc.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: svc.rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return null
        return node.takeIf { it.isEditable }
    }

    /** The field's real text, or "" if it is only showing its hint, or null if the app hides it. */
    private fun currentText(node: AccessibilityNodeInfo): String? {
        if (node.isShowingHintText) return ""
        return node.text?.toString()
    }

    private fun selection(node: AccessibilityNodeInfo, length: Int): Pair<Int, Int> {
        var s = node.textSelectionStart
        var e = node.textSelectionEnd
        if (s !in 0..length) s = length
        if (e !in 0..length) e = s
        return if (s <= e) s to e else e to s
    }

    private fun isSafeForSetText(node: AccessibilityNodeInfo, current: String): Boolean {
        if (node.isPassword) return false
        if (current.length > MAX_SET_TEXT_LENGTH) return false
        if (node.maxTextLength in 0..current.length) return false
        if (node.textSelectionStart < 0 && current.isNotEmpty()) return false // cursor unknown
        // Browsers/WebViews may expose only part of the content; replacing it could lose text.
        var p: AccessibilityNodeInfo? = node
        var depth = 0
        while (p != null && depth++ < 25) {
            val cls = p.className?.toString().orEmpty()
            if (cls.contains("WebView")) return false
            p = p.parent
        }
        val pkg = node.packageName?.toString().orEmpty()
        if (pkg in BROWSERS) return false
        return true
    }

    private fun pasteViaClipboard(context: Context, node: AccessibilityNodeInfo, text: String): Boolean {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return false
        // Android only lets the focused app or the default keyboard read the clipboard, so this is
        // often null from the bubble; in that case the clipboard is cleared afterwards instead of
        // leaving the dictation on it.
        val previous: ClipData? = runCatching { cm.primaryClip }.getOrNull()
        cm.setPrimaryClip(sensitiveClip(text))
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        main.postDelayed({
            runCatching {
                if (previous != null) cm.setPrimaryClip(previous) else cm.clearPrimaryClip()
            }
        }, CLIP_RESTORE_DELAY_MS)
        return ok
    }

    private fun sensitiveClip(text: String): ClipData =
        ClipData.newPlainText("dictation", text).apply {
            // Keeps keyboards' clipboard history / the system preview from showing the text.
            // ClipDescription.EXTRA_IS_SENSITIVE (API 33); the literal also works on 31-32 where it's ignored.
            description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
        }

    private val BROWSERS = setOf(
        "com.android.chrome", "org.mozilla.firefox", "com.brave.browser", "com.microsoft.emmx",
        "com.opera.browser", "com.sec.android.app.sbrowser", "com.heytap.browser", "com.duckduckgo.mobile.android",
    )
}

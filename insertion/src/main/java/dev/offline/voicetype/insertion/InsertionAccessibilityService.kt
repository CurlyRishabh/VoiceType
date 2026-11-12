package dev.offline.voicetype.insertion

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Minimal accessibility service: exposes the focused input field to [TextInserter] and reports
 * whether a soft keyboard window is on screen (so the bubble can auto-hide). Event text and other
 * screen content are ignored.
 */
class InsertionAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = this
        updateKeyboardVisibility()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> updateKeyboardVisibility()
            else -> Unit
        }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        setKeyboardVisible(false)
        super.onDestroy()
    }

    private fun updateKeyboardVisibility() {
        val visible = runCatching { windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }.getOrDefault(false)
        setKeyboardVisible(visible)
    }

    fun interface KeyboardListener {
        fun onKeyboardVisibilityChanged(visible: Boolean)
    }

    companion object {
        @Volatile var instance: InsertionAccessibilityService? = null
            private set

        @Volatile var keyboardVisible: Boolean = false
            private set

        private val listeners = CopyOnWriteArraySet<KeyboardListener>()

        fun isRunning(): Boolean = instance != null

        fun addKeyboardListener(l: KeyboardListener) { listeners += l }
        fun removeKeyboardListener(l: KeyboardListener) { listeners -= l }

        private fun setKeyboardVisible(visible: Boolean) {
            if (keyboardVisible == visible) return
            keyboardVisible = visible
            listeners.forEach { it.onKeyboardVisibilityChanged(visible) }
        }
    }
}

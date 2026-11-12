package dev.offline.voicetype.ime

import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.ColorStateList
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.ContextThemeWrapper
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ImageButton
import android.widget.TextView
import androidx.core.content.ContextCompat
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.cleanup.CleanupResult
import dev.offline.voicetype.cleanup.TextJoin
import dev.offline.voicetype.dictation.DictationController
import dev.offline.voicetype.dictation.DictationController.State
import dev.offline.voicetype.ui.LevelMeterView
import dev.offline.voicetype.ui.SettingsActivity
import dev.offline.voicetype.ui.SetupActivity

/**
 * Voice keyboard: big mic (tap = toggle with auto-stop, hold = push-to-talk), level meter,
 * backspace, space, enter and a switch-keyboard key. Text goes in through commitText().
 */
class VoiceImeService : InputMethodService(), DictationController.Callback {

    private lateinit var controller: DictationController
    private val main = Handler(Looper.getMainLooper())

    private var status: TextView? = null
    private var level: LevelMeterView? = null
    private var mic: ImageButton? = null
    private var isClient = false
    private var plainTextField = true

    override fun onCreate() {
        super.onCreate()
        controller = DictationController(this, this)
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    override fun onCreateInputView(): View {
        val themed = ContextThemeWrapper(this, R.style.Theme_VoiceType)
        val root = LayoutInflater.from(themed).inflate(R.layout.ime_keyboard, null)
        status = root.findViewById(R.id.status)
        level = root.findViewById(R.id.level)
        mic = root.findViewById<ImageButton>(R.id.mic).also { setUpMic(it) }

        root.findViewById<ImageButton>(R.id.space).setOnClickListener { commit(" ") }
        root.findViewById<ImageButton>(R.id.enter).setOnClickListener { enter() }
        root.findViewById<ImageButton>(R.id.backspace).also(::setUpBackspace)
        root.findViewById<ImageButton>(R.id.switch_kb).apply {
            setOnClickListener { if (!switchToPreviousInputMethod()) showPicker() }
            setOnLongClickListener { showPicker(); true }
        }
        root.findViewById<ImageButton>(R.id.settings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        render(controller.state)
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        plainTextField = info?.let(::isPlainText) ?: true
        if (!isClient) {
            isClient = true
            app.clientActive()
        }
        app.warmUp() // load models now so the first dictation is fast
        render(controller.state)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (controller.state == State.LISTENING) controller.cancel()
        if (isClient) {
            isClient = false
            app.clientInactive()
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        controller.cancel()
        if (isClient) app.clientInactive()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ mic

    @SuppressLint("ClickableViewAccessibility")
    private fun setUpMic(button: ImageButton) {
        var holding = false
        val startHold = Runnable {
            if (controller.state == State.IDLE && startDictation(autoStop = false)) {
                holding = true
                button.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            }
        }
        button.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    holding = false
                    if (controller.state == State.IDLE) main.postDelayed(startHold, HOLD_MS)
                    v.isPressed = true
                }
                MotionEvent.ACTION_UP -> {
                    v.isPressed = false
                    main.removeCallbacks(startHold)
                    if (holding) {
                        holding = false
                        controller.stop()
                    } else {
                        v.performClick()
                        when (controller.state) {
                            State.IDLE -> startDictation(autoStop = true)
                            State.LISTENING -> controller.stop()
                            else -> Unit
                        }
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    main.removeCallbacks(startHold)
                    if (holding) {
                        holding = false
                        controller.stop()
                    }
                }
            }
            true
        }
    }

    private fun startDictation(autoStop: Boolean): Boolean {
        val ic = currentInputConnection
        val before = ic?.getTextBeforeCursor(200, 0)?.toString()
        val after = ic?.getTextAfterCursor(80, 0)?.toString()
        val ok = controller.start(
            DictationController.Target(
                startsSentence = TextJoin.startsSentence(before),
                endsSentence = TextJoin.endsSentence(after),
                plainText = plainTextField,
            ),
            autoStop = autoStop,
        )
        if (!ok && !controller.hasMicPermission()) {
            startActivity(Intent(this, SetupActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        return ok
    }

    // ------------------------------------------------------------------ callbacks

    override fun onState(state: State) = render(state)

    override fun onLevel(level: Float) {
        this.level?.setLevel(level)
    }

    override fun onResult(result: CleanupResult) {
        val ic = currentInputConnection ?: return
        val before = ic.getTextBeforeCursor(1, 0)?.toString()
        val after = ic.getTextAfterCursor(1, 0)?.toString()
        commit(TextJoin.pad(result.text, before, after))
        status?.text = getString(R.string.ime_tap_to_speak)
    }

    override fun onNoSpeech() {
        status?.text = getString(R.string.ime_no_speech)
    }

    override fun onError(message: String) {
        status?.text = message
    }

    private fun render(state: State) {
        val color = when (state) {
            State.IDLE -> R.color.brand
            State.LISTENING -> R.color.recording
            State.TRANSCRIBING, State.POLISHING -> R.color.busy
        }
        mic?.backgroundTintList = ColorStateList.valueOf(ContextCompat.getColor(this, color))
        mic?.imageTintList = ColorStateList.valueOf(0xFFFFFFFF.toInt())
        level?.active = state == State.LISTENING
        status?.text = when (state) {
            State.IDLE -> status?.text?.takeUnless { it == getString(R.string.ime_listening) || it == getString(R.string.ime_transcribing) || it == getString(R.string.ime_polishing) }
                ?: getString(R.string.ime_tap_to_speak)
            State.LISTENING -> getString(R.string.ime_listening)
            State.TRANSCRIBING -> getString(R.string.ime_transcribing)
            State.POLISHING -> getString(R.string.ime_polishing)
        }
    }

    // ------------------------------------------------------------------ keys

    private fun commit(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    private fun enter() {
        val info = currentInputEditorInfo
        val action = (info?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
        val noEnterAction = (info?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
        val multiLine = (info?.inputType ?: 0) and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0
        if (!multiLine && !noEnterAction && action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            currentInputConnection?.performEditorAction(action)
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setUpBackspace(button: ImageButton) {
        val repeat = object : Runnable {
            override fun run() {
                deleteOne()
                main.postDelayed(this, 60)
            }
        }
        button.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    deleteOne()
                    main.postDelayed(repeat, 450)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    main.removeCallbacks(repeat)
                    if (e.actionMasked == MotionEvent.ACTION_UP) v.performClick()
                }
            }
            true
        }
    }

    private fun deleteOne() {
        val ic = currentInputConnection ?: return
        val selected = ic.getSelectedText(0)
        if (!selected.isNullOrEmpty()) {
            ic.commitText("", 1)
        } else if (!ic.deleteSurroundingTextInCodePoints(1, 0)) {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        }
    }

    private fun showPicker() {
        getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
    }

    private fun isPlainText(info: EditorInfo): Boolean {
        val cls = info.inputType and InputType.TYPE_MASK_CLASS
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        if (cls != InputType.TYPE_CLASS_TEXT) return false
        return variation !in setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_URI,
        )
    }

    private companion object {
        const val HOLD_MS = 350L
    }
}

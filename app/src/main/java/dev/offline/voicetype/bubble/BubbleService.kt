package dev.offline.voicetype.bubble

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.ColorStateList
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings as AndroidSettings
import android.util.Log
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.Toast
import androidx.core.content.ContextCompat
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.cleanup.CleanupResult
import dev.offline.voicetype.cleanup.TextJoin
import dev.offline.voicetype.dictation.DictationController
import dev.offline.voicetype.dictation.DictationController.State
import dev.offline.voicetype.insertion.InsertionAccessibilityService
import dev.offline.voicetype.insertion.TextInserter
import dev.offline.voicetype.ui.SettingsActivity
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Wispr Flow–style floating mic. Runs as a foreground service (low-priority notification) so
 * OxygenOS doesn't kill it. Tap to toggle (auto-stops on silence) or hold to talk, drag to move.
 * The dictated text is inserted into the focused field by [TextInserter].
 */
class BubbleService : Service(), DictationController.Callback {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var wm: WindowManager
    private lateinit var controller: DictationController
    private var bubble: FrameLayout? = null
    private var icon: ImageView? = null
    private var params: WindowManager.LayoutParams? = null

    /** True once a foreground-service start happened while our UI was visible (mic allowed). */
    private var micCapable = false
    private var pendingStartAfterMicAccess = false

    private val keyboardListener = InsertionAccessibilityService.KeyboardListener { main.post { updateVisibility() } }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        wm = getSystemService(WindowManager::class.java)
        controller = DictationController(this, this)
        goForeground()
        app.clientActive()
        app.warmUp()
        InsertionAccessibilityService.addKeyboardListener(keyboardListener)
        showBubble()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            app.settings.bubbleEnabled = false
            stopSelf()
            return START_NOT_STICKY
        }
        if (!AndroidSettings.canDrawOverlays(this)) {
            Toast.makeText(this, R.string.bubble_no_overlay, Toast.LENGTH_LONG).show()
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        controller.cancel()
        InsertionAccessibilityService.removeKeyboardListener(keyboardListener)
        bubble?.let { runCatching { wm.removeView(it) } }
        bubble = null
        app.clientInactive()
        if (instance === this) instance = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------ foreground / mic access

    /**
     * Android only lets a foreground service use the microphone in the background if the service
     * was (re)started while the app was visible. After a reboot that isn't the case, so the first
     * tap bounces through the invisible [MicAccessActivity] to obtain it.
     */
    private fun goForeground() {
        val visible = app.visibleActivities > 0
        val micType = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val special = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                try {
                    startForeground(NOTIFICATION_ID, notification(), micType or special)
                    micCapable = visible
                } catch (e: SecurityException) {
                    startForeground(NOTIFICATION_ID, notification(), special)
                    micCapable = false
                }
            } else {
                startForeground(NOTIFICATION_ID, notification(), micType)
                micCapable = visible
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
            micCapable = false
        }
    }

    /** Re-reads settings that affect the overlay. */
    fun refresh() = updateVisibility()

    /** Called by [MicAccessActivity] while it is on screen. */
    fun onMicAccessGranted() {
        goForeground()
        if (pendingStartAfterMicAccess) {
            pendingStartAfterMicAccess = false
            main.postDelayed({ startDictation(autoStop = true) }, 250)
        }
    }

    // ------------------------------------------------------------------ overlay

    @SuppressLint("ClickableViewAccessibility")
    private fun showBubble() {
        if (bubble != null || !AndroidSettings.canDrawOverlays(this)) return
        val themed = ContextThemeWrapper(this, R.style.Theme_VoiceType)
        val size = dp(56)
        val iv = ImageView(themed).apply {
            setImageResource(R.drawable.ic_mic)
            setBackgroundResource(R.drawable.bg_mic)
            scaleType = ImageView.ScaleType.CENTER
            elevation = dp(6).toFloat()
            contentDescription = getString(R.string.cd_mic)
            imageTintList = ColorStateList.valueOf(0xFFFFFFFF.toInt())
        }
        val frame = FrameLayout(themed).apply {
            setPadding(dp(6), dp(6), dp(6), dp(6))
            addView(iv, FrameLayout.LayoutParams(size, size))
        }
        val screenW = resources.displayMetrics.widthPixels
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // Never take focus: the text field in the app below must keep it.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = app.settings.bubbleX.takeIf { it >= 0 } ?: (screenW - size - dp(24))
            y = app.settings.bubbleY
        }
        frame.setOnTouchListener(BubbleTouch(lp))
        wm.addView(frame, lp)
        bubble = frame
        icon = iv
        params = lp
        render(controller.state)
        updateVisibility()
    }

    private fun updateVisibility() {
        val b = bubble ?: return
        val busy = controller.state != State.IDLE
        // Keyboard visibility is only known through the accessibility service; without it, always show.
        val show = !app.settings.bubbleHideWithKeyboard || !InsertionAccessibilityService.isRunning() ||
            InsertionAccessibilityService.keyboardVisible || busy
        b.visibility = if (show) View.VISIBLE else View.GONE
    }

    private inner class BubbleTouch(private val lp: WindowManager.LayoutParams) : View.OnTouchListener {
        private val slop = ViewConfiguration.get(this@BubbleService).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var holding = false

        private val holdStart = Runnable {
            if (!dragging && controller.state == State.IDLE && startDictation(autoStop = false)) {
                holding = true
                bubble?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
        }

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY
                    startX = lp.x; startY = lp.y
                    dragging = false; holding = false
                    if (app.settings.bubbleHoldToTalk && controller.state == State.IDLE) main.postDelayed(holdStart, HOLD_MS)
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (!holding && (dragging || abs(dx) > slop || abs(dy) > slop)) {
                        dragging = true
                        main.removeCallbacks(holdStart)
                        lp.x = (startX + dx).roundToInt().coerceAtLeast(0)
                        lp.y = (startY + dy).roundToInt().coerceAtLeast(0)
                        runCatching { wm.updateViewLayout(v, lp) }
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    main.removeCallbacks(holdStart)
                    when {
                        dragging -> {
                            app.settings.bubbleX = lp.x
                            app.settings.bubbleY = lp.y
                        }
                        holding -> controller.stop()
                        e.actionMasked == MotionEvent.ACTION_UP -> {
                            v.performClick()
                            onTap()
                        }
                    }
                    dragging = false
                    holding = false
                }
            }
            return true
        }
    }

    private fun onTap() {
        when (controller.state) {
            State.IDLE -> startDictation(autoStop = true)
            State.LISTENING -> controller.stop()
            else -> Unit
        }
    }

    private fun startDictation(autoStop: Boolean): Boolean {
        if (!micCapable && app.visibleActivities == 0) {
            pendingStartAfterMicAccess = autoStop
            startActivity(
                Intent(this, MicAccessActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
            return false
        }
        val ctx = TextInserter.focusedFieldContext()
        return controller.start(
            DictationController.Target(
                startsSentence = TextJoin.startsSentence(ctx?.before),
                endsSentence = TextJoin.endsSentence(ctx?.after),
                plainText = true,
            ),
            autoStop = autoStop,
        )
    }

    // ------------------------------------------------------------------ dictation callbacks

    override fun onState(state: State) {
        render(state)
        updateVisibility()
    }

    override fun onLevel(level: Float) {
        val s = 1f + 0.25f * level
        icon?.animate()?.scaleX(s)?.scaleY(s)?.setDuration(60)?.start()
    }

    override fun onResult(result: CleanupResult) {
        val message = when (TextInserter.insert(this, result.text)) {
            TextInserter.Outcome.SET_TEXT, TextInserter.Outcome.PASTED -> null
            TextInserter.Outcome.NO_SERVICE -> R.string.bubble_copied_no_service
            TextInserter.Outcome.NO_FOCUSED_FIELD -> R.string.bubble_copied_no_field
            TextInserter.Outcome.FAILED -> R.string.bubble_copied_failed
        }
        if (message != null) {
            TextInserter.copyToClipboard(this, result.text)
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    override fun onNoSpeech() {
        Toast.makeText(this, R.string.ime_no_speech, Toast.LENGTH_SHORT).show()
    }

    override fun onError(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun render(state: State) {
        val color = when (state) {
            State.IDLE -> R.color.brand
            State.LISTENING -> R.color.recording
            State.TRANSCRIBING, State.POLISHING -> R.color.busy
        }
        icon?.backgroundTintList = ColorStateList.valueOf(ContextCompat.getColor(this, color))
        if (state != State.LISTENING) icon?.animate()?.scaleX(1f)?.scaleY(1f)?.setDuration(120)?.start()
        icon?.alpha = if (state == State.TRANSCRIBING || state == State.POLISHING) 0.8f else 1f
    }

    // ------------------------------------------------------------------ notification

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.bubble_channel), NotificationManager.IMPORTANCE_MIN).apply {
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, SettingsActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, BubbleService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle(getString(R.string.bubble_notification_title))
            .setContentText(getString(R.string.bubble_notification_text))
            .setContentIntent(open)
            .setOngoing(true)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(Notification.Action.Builder(null, getString(R.string.bubble_turn_off), stop).build())
            .build()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "BubbleService"
        private const val CHANNEL = "bubble"
        private const val NOTIFICATION_ID = 42
        private const val HOLD_MS = 300L
        const val ACTION_STOP = "dev.offline.voicetype.bubble.STOP"

        @Volatile var instance: BubbleService? = null
            private set

        fun start(context: Context) {
            if (!AndroidSettings.canDrawOverlays(context)) return
            ContextCompat.startForegroundService(context, Intent(context, BubbleService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BubbleService::class.java))
        }
    }
}

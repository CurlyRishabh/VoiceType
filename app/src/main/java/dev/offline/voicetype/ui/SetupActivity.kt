package dev.offline.voicetype.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.materialswitch.MaterialSwitch
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.bubble.BubbleService
import dev.offline.voicetype.engine.ModelSlot

/**
 * Setup wizard: one card per step with a live status, re-checked every time the screen resumes
 * (most steps send the user to a system settings page and back).
 */
class SetupActivity : AppCompatActivity() {

    private enum class Status { DONE, TODO, MANUAL }

    private class Step(
        val title: Int,
        val desc: Int,
        val status: () -> Status,
        val actions: List<Pair<Int, () -> Unit>>,
    )

    private lateinit var steps: List<Step>
    private val rows = mutableListOf<View>()

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_setup)
        title = getString(R.string.setup_title)

        steps = listOf(
            Step(R.string.step_mic_title, R.string.step_mic_desc, {
                if (has(Manifest.permission.RECORD_AUDIO)) Status.DONE else Status.TODO
            }, listOf(R.string.action_grant to {
                permissionLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS))
            })),
            Step(R.string.step_models_title, R.string.step_models_desc, {
                val m = app.models
                val speech = m.isReady(ModelSlot.MOONSHINE) || m.isReady(ModelSlot.WHISPER)
                if (speech && m.isReady(ModelSlot.VAD)) Status.DONE else Status.TODO
            }, listOf(R.string.action_import to { startActivity(Intent(this, ModelsActivity::class.java)) })),
            Step(R.string.step_kb_enable_title, R.string.step_kb_enable_desc, {
                if (SystemSetup.isKeyboardEnabled(this)) Status.DONE else Status.TODO
            }, listOf(R.string.action_open to { SystemSetup.openKeyboardSettings(this) })),
            Step(R.string.step_kb_select_title, R.string.step_kb_select_desc, {
                if (SystemSetup.isKeyboardSelected(this)) Status.DONE else Status.MANUAL
            }, listOf(R.string.action_choose to { SystemSetup.showKeyboardPicker(this) })),
            Step(R.string.step_overlay_title, R.string.step_overlay_desc, {
                if (Settings.canDrawOverlays(this)) Status.DONE else Status.TODO
            }, listOf(R.string.action_allow to { SystemSetup.openOverlaySettings(this) })),
            Step(R.string.step_a11y_title, R.string.step_a11y_desc, {
                if (SystemSetup.isAccessibilityEnabled(this)) Status.DONE else Status.TODO
            }, listOf(R.string.action_review to { startActivity(Intent(this, AccessibilityExplainerActivity::class.java)) })),
            Step(R.string.step_battery_title, R.string.step_battery_desc, {
                if (SystemSetup.isBatteryUnrestricted(this)) Status.DONE else Status.TODO
            }, listOf(
                R.string.action_allow to { SystemSetup.requestUnrestrictedBattery(this) },
                R.string.action_app_battery to { SystemSetup.openAppDetails(this) },
            )),
            Step(R.string.step_autolaunch_title, R.string.step_autolaunch_desc, { Status.MANUAL },
                listOf(R.string.action_open to { SystemSetup.openAutoLaunchSettings(this) })),
        )

        val container = findViewById<LinearLayout>(R.id.steps)
        val inflater = LayoutInflater.from(this)
        for (step in steps) {
            val row = inflater.inflate(R.layout.item_setup_step, container, false)
            row.findViewById<TextView>(R.id.title).setText(step.title)
            row.findViewById<TextView>(R.id.desc).setText(step.desc)
            val buttons = row.findViewById<LinearLayout>(R.id.buttons)
            for ((label, action) in step.actions) {
                val button = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
                    setText(label)
                    setOnClickListener { action() }
                }
                buttons.addView(
                    button,
                    LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                        .apply { marginStart = (8 * resources.displayMetrics.density).toInt() },
                )
            }
            container.addView(row)
            rows += row
        }

        findViewById<MaterialSwitch>(R.id.bubble_switch).setOnCheckedChangeListener { sw, checked ->
            if (!sw.isPressed) return@setOnCheckedChangeListener
            if (checked && !Settings.canDrawOverlays(this)) {
                sw.isChecked = false
                Toast.makeText(this, R.string.bubble_no_overlay, Toast.LENGTH_LONG).show()
                SystemSetup.openOverlaySettings(this)
                return@setOnCheckedChangeListener
            }
            app.settings.bubbleEnabled = checked
            if (checked) BubbleService.start(this) else BubbleService.stop(this)
        }
        findViewById<Button>(R.id.open_settings).setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
    }

    override fun onResume() {
        super.onResume()
        refresh()
        // Re-starting the bubble while our UI is visible gives it microphone access.
        if (app.settings.bubbleEnabled && Settings.canDrawOverlays(this)) BubbleService.start(this)
    }

    private fun refresh() {
        steps.forEachIndexed { i, step ->
            val row = rows[i]
            val s = step.status()
            val (label, color, icon) = when (s) {
                Status.DONE -> Triple(R.string.status_done, R.color.ok_green, R.drawable.ic_check)
                Status.TODO -> Triple(R.string.status_todo, R.color.recording, R.drawable.ic_todo)
                Status.MANUAL -> Triple(R.string.status_manual, R.color.todo_grey, R.drawable.ic_todo)
            }
            val tint = ColorStateList.valueOf(ContextCompat.getColor(this, color))
            row.findViewById<TextView>(R.id.status).apply { setText(label); setTextColor(tint) }
            row.findViewById<ImageView>(R.id.icon).apply { setImageResource(icon); imageTintList = tint }
        }
        findViewById<MaterialSwitch>(R.id.bubble_switch).isChecked = app.settings.bubbleEnabled
    }

    private fun has(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}

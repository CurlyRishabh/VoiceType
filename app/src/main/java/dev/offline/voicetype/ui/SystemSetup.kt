package dev.offline.voicetype.ui

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import dev.offline.voicetype.ime.VoiceImeService
import dev.offline.voicetype.insertion.InsertionAccessibilityService

/** Status checks and deep links for the setup wizard, including OnePlus/OxygenOS specifics. */
object SystemSetup {

    fun imeId(context: Context) = ComponentName(context, VoiceImeService::class.java).flattenToShortString()

    fun isKeyboardEnabled(context: Context): Boolean {
        val imm = context.getSystemService(InputMethodManager::class.java)
        return imm.enabledInputMethodList.any { it.packageName == context.packageName }
    }

    fun isKeyboardSelected(context: Context): Boolean {
        val current = Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) ?: return false
        return ComponentName.unflattenFromString(current)?.packageName == context.packageName
    }

    fun isAccessibilityEnabled(context: Context): Boolean {
        if (InsertionAccessibilityService.isRunning()) return true
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(context, InsertionAccessibilityService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun isBatteryUnrestricted(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** Shows the system "Let app always run in background?" dialog (sets the app to Unrestricted). */
    @SuppressLint("BatteryLife") // personal sideloaded app; the user asked for this
    fun requestUnrestrictedBattery(context: Context) {
        val ok = tryStart(context, Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
        if (!ok) openAppDetails(context)
    }

    fun openAppDetails(context: Context) {
        tryStart(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
    }

    /**
     * OnePlus "auto launch" lists live in different places across OxygenOS versions; try the known
     * screens, newest first, and fall back to App info (Battery usage → Allow auto launch).
     */
    fun openAutoLaunchSettings(context: Context) {
        val candidates = listOf(
            ComponentName("com.oplus.battery", "com.oplus.startupapp.view.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.privacypermissionsentry.PermissionTopActivity"),
            ComponentName("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
        )
        for (c in candidates) {
            if (tryStart(context, Intent().setComponent(c))) return
        }
        openAppDetails(context)
    }

    fun openKeyboardSettings(context: Context) = tryStart(context, Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))

    fun showKeyboardPicker(context: Context) {
        context.getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }

    fun openOverlaySettings(context: Context) =
        tryStart(context, Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")))

    fun openAccessibilitySettings(context: Context) = tryStart(context, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}

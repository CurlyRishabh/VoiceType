package dev.offline.voicetype.bubble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.offline.voicetype.app

/** Brings the bubble back after a reboot or app update, if the user turned it on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!context.app.settings.bubbleEnabled) return
        runCatching { BubbleService.start(context) }
            .onFailure { Log.w("BootReceiver", "could not start bubble", it) }
    }
}

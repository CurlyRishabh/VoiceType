package dev.offline.voicetype.bubble

import android.app.Activity

/**
 * Invisible, finishes immediately. While it is on screen the app counts as "in use", which lets
 * [BubbleService] re-enter the foreground with microphone access (needed once after a reboot or
 * after Android restarted the service in the background).
 */
class MicAccessActivity : Activity() {

    override fun onResume() {
        super.onResume()
        BubbleService.instance?.onMicAccessGranted()
        finish() // no animations: see Theme.VoiceType.Invisible
    }
}

package dev.offline.voicetype.ime

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import dev.offline.voicetype.app
import dev.offline.voicetype.cleanup.CleanupResult
import dev.offline.voicetype.dictation.DictationController
import dev.offline.voicetype.dictation.DictationController.State

/**
 * Exposes VoiceType as an Android speech recogniser, so keyboards and apps that use
 * SpeechRecognizer can dictate offline through it (select it under Settings → Apps →
 * Default apps → Assist & voice input / "Voice input" on OxygenOS).
 */
class VoiceRecognitionService : RecognitionService() {

    private var controller: DictationController? = null
    private var listener: Callback? = null

    override fun onStartListening(intent: Intent?, callback: Callback) {
        controller?.cancel()
        listener = callback
        app.clientActive()
        val c = DictationController(this, object : DictationController.Callback {
            override fun onState(state: State) {
                safely {
                    when (state) {
                        State.LISTENING -> callback.readyForSpeech(Bundle())
                        State.TRANSCRIBING -> callback.endOfSpeech()
                        else -> Unit
                    }
                }
            }

            override fun onSpeechStarted() = safely { callback.beginningOfSpeech() }

            // SpeechRecognizer RMS is roughly -2..10 dB.
            override fun onLevel(level: Float) = safely { callback.rmsChanged(-2f + level * 12f) }

            override fun onResult(result: CleanupResult) {
                safely {
                    callback.results(Bundle().apply {
                        putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(result.text))
                        putFloatArray(SpeechRecognizer.CONFIDENCE_SCORES, floatArrayOf(1f))
                    })
                }
                done()
            }

            override fun onNoSpeech() {
                safely { callback.error(SpeechRecognizer.ERROR_SPEECH_TIMEOUT) }
                done()
            }

            override fun onError(message: String) {
                val code = when {
                    !controller!!.hasMicPermission() -> SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS
                    "imported" in message -> SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE
                    else -> SpeechRecognizer.ERROR_CLIENT
                }
                safely { callback.error(code) }
                done()
            }
        })
        controller = c
        c.start(DictationController.Target(startsSentence = true, endsSentence = true, plainText = true), autoStop = true)
    }

    override fun onStopListening(callback: Callback) {
        controller?.stop()
    }

    override fun onCancel(callback: Callback) {
        controller?.cancel()
        done()
    }

    override fun onDestroy() {
        controller?.cancel()
        done()
        super.onDestroy()
    }

    private fun done() {
        if (listener != null) {
            listener = null
            app.clientInactive()
        }
    }

    private inline fun safely(block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
            // Caller went away (RemoteException) – nothing to deliver to.
        }
    }
}

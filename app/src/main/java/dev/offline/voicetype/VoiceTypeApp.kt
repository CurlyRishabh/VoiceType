package dev.offline.voicetype

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.os.Bundle
import dev.offline.voicetype.cleanup.CleanupPipeline
import dev.offline.voicetype.data.HistoryStore
import dev.offline.voicetype.data.ModelStore
import dev.offline.voicetype.data.Settings
import dev.offline.voicetype.engine.SpeechEngineHost
import dev.offline.voicetype.polish.LiteRtPolisher

/** Process-wide singletons. The IME, bubble, recogniser and UI all share one warm model. */
class VoiceTypeApp : Application() {

    lateinit var settings: Settings private set
    lateinit var models: ModelStore private set
    lateinit var history: HistoryStore private set
    lateinit var speech: SpeechEngineHost private set
    lateinit var polisher: LiteRtPolisher private set
    lateinit var pipeline: CleanupPipeline private set

    /** Number of our activities currently started (visible). */
    @Volatile var visibleActivities = 0
        private set

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        models = ModelStore(this)
        history = HistoryStore(this)
        speech = SpeechEngineHost(models.root)
        polisher = LiteRtPolisher(
            modelFile = { models.llmFile() },
            useGpu = { settings.polishGpu },
            cacheDir = noBackupFilesDir,
        )
        pipeline = CleanupPipeline(polisher, timeoutMillis = POLISH_TIMEOUT_MS)

        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(a: Activity) { visibleActivities++ }
            override fun onActivityStopped(a: Activity) { visibleActivities = maxOf(0, visibleActivities - 1) }
            override fun onActivityCreated(a: Activity, b: Bundle?) = Unit
            override fun onActivityResumed(a: Activity) = Unit
            override fun onActivityPaused(a: Activity) = Unit
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) = Unit
            override fun onActivityDestroyed(a: Activity) = Unit
        })
    }

    /** Called when the keyboard or bubble appears: load models in the background. */
    fun warmUp() {
        speech.warmUp(settings.engineSpec())
        if (settings.polishEnabled) polisher.warmUp()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        speech.onTrimMemory(level)
        @Suppress("DEPRECATION")
        val severe = level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND
        if (severe || (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN && activeClients == 0)) polisher.release()
    }

    @Volatile var activeClients = 0
        private set

    fun clientActive() {
        activeClients++
        speech.clientActive()
    }

    fun clientInactive() {
        activeClients = maxOf(0, activeClients - 1)
        speech.clientInactive()
    }

    companion object {
        const val POLISH_TIMEOUT_MS = 3_000L
    }
}

val Context.app: VoiceTypeApp get() = applicationContext as VoiceTypeApp

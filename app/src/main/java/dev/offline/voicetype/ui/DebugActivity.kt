package dev.offline.voicetype.ui

import android.Manifest
import android.app.ActivityManager
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import dev.offline.voicetype.BuildConfig
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.engine.DictationRecorder
import dev.offline.voicetype.engine.EngineKind
import dev.offline.voicetype.engine.EngineSpec
import dev.offline.voicetype.engine.ModelSlot
import dev.offline.voicetype.engine.PerfLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Real-time factor (decode time / audio length) for recent dictations, model load times and a
 * 5-second benchmark that runs every imported speech engine on the same recording.
 */
class DebugActivity : AppCompatActivity() {

    private lateinit var out: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        out = TextView(this).apply {
            setTextIsSelectable(true)
            typeface = android.graphics.Typeface.MONOSPACE
            textSize = 12f
        }
        val bench = Button(this).apply { setText(R.string.debug_benchmark); setOnClickListener { benchmark() } }
        val refresh = Button(this).apply { setText(R.string.debug_refresh); setOnClickListener { render() } }
        val clearRec = Button(this).apply {
            setText(R.string.debug_clear_recordings)
            setOnClickListener { recordingsDir().listFiles()?.forEach { it.delete() }; render() }
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            addView(bench); addView(refresh); addView(clearRec); addView(out)
        }
        setContentView(ScrollView(this).apply { addView(column) })
        render()
    }

    private fun recordingsDir() = File(noBackupFilesDir, "recordings")

    private fun render(extra: String = "") {
        val am = getSystemService(ActivityManager::class.java)
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val fmt = SimpleDateFormat("HH:mm:ss", Locale.US)
        val sb = StringBuilder()
        sb.appendLine("VoiceType ${BuildConfig.VERSION_NAME} · ${android.os.Build.MODEL} · Android ${android.os.Build.VERSION.RELEASE}")
        sb.appendLine("CPU cores: ${Runtime.getRuntime().availableProcessors()} · RAM free ${mem.availMem / 1_048_576} / ${mem.totalMem / 1_048_576} MB")
        sb.appendLine("Inference threads: 4")
        sb.appendLine("Speech model loaded: ${app.speech.loadedSpec?.let { "${it.kind} (${it.language.ifEmpty { "auto" }})" } ?: "none"} · last load ${app.speech.lastLoadMillis} ms")
        sb.appendLine("Polish model: ${app.models.llmFile()?.name ?: "not imported"} · ready=${app.polisher.isReady} · last load ${app.polisher.lastLoadMillis} ms")
        app.polisher.lastError?.let { sb.appendLine("Polish load error: $it") }
        val recs = recordingsDir().listFiles()?.size ?: 0
        sb.appendLine("Keep recordings: ${app.settings.keepRecordings} · kept files: $recs")
        sb.appendLine()
        if (extra.isNotEmpty()) sb.appendLine(extra).appendLine()
        sb.appendLine("Recent dictations (RTF < 1 = faster than real time):")
        val recent = PerfLog.recent()
        if (recent.isEmpty()) sb.appendLine("  none yet")
        for (e in recent) {
            sb.append("  ${fmt.format(Date(e.timestamp))} ${e.engine.padEnd(13)} audio ${e.audioMillis}ms decode ${e.decodeMillis}ms RTF ${"%.3f".format(e.rtf)}")
            if (e.loadMillis > 0) sb.append(" load ${e.loadMillis}ms")
            if (e.polishMillis >= 0) sb.append(" polish ${e.polishMillis}ms")
            e.polishNote?.let { sb.append(" [$it]") }
            sb.appendLine()
        }
        out.text = sb
    }

    private fun benchmark() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            render("Grant the microphone permission first (Setup).")
            return
        }
        render(getString(R.string.debug_recording))
        lifecycleScope.launch {
            val recorder = DictationRecorder(null, DictationRecorder.Config(autoStop = false), object : DictationRecorder.Listener {})
            recorder.start()
            delay(5_000)
            val captured = withContext(Dispatchers.IO) { recorder.stop() }
            val englishChunks = captured.chunks()
            val report = StringBuilder("Benchmark on ${captured.durationMillis} ms of audio:\n")
            val specs = buildList {
                if (app.models.isReady(ModelSlot.MOONSHINE)) add(EngineSpec(EngineKind.FAST_ENGLISH, "en"))
                if (app.models.isReady(ModelSlot.WHISPER)) {
                    add(EngineSpec(EngineKind.HINDI_ENGLISH, "en"))
                    add(EngineSpec(EngineKind.HINDI_ENGLISH, "hi"))
                }
            }
            if (specs.isEmpty()) report.appendLine("No speech model imported.")
            for (spec in specs) {
                val chunks = if (spec.kind == EngineKind.HINDI_ENGLISH) captured.chunks(true, spec.language) else englishChunks
                val r = withContext(Dispatchers.IO) { runCatching { app.speech.transcribe(spec, chunks, captured.durationMillis).get() } }
                chunks.forEach { it.fill(0f) }
                r.onSuccess {
                    report.appendLine("${spec.kind}/${spec.language}: load ${it.loadMillis} ms, decode ${it.decodeMillis} ms, RTF ${"%.3f".format(it.rtf)}")
                    report.appendLine("  \"${it.text}\"")
                }.onFailure { report.appendLine("${spec.kind}/${spec.language}: ${it.cause?.message ?: it.message}") }
            }
            englishChunks.forEach { it.fill(0f) }
            captured.pcm.fill(0)
            render(report.toString())
            app.warmUp() // restore the user's selected engine
        }
    }
}

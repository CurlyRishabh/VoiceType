package dev.offline.voicetype.ui

import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SwitchPreferenceCompat
import dev.offline.voicetype.R
import dev.offline.voicetype.app
import dev.offline.voicetype.bubble.BubbleService
import dev.offline.voicetype.data.Settings

class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(android.R.id.content, SettingsFragment()).commit()
        }
    }
}

class SettingsFragment : PreferenceFragmentCompat(), SharedPreferences.OnSharedPreferenceChangeListener {

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        setPreferencesFromResource(R.xml.preferences, rootKey)
        link("models", ModelsActivity::class.java)
        link("dictionary", DictionaryActivity::class.java)
        link("history", HistoryActivity::class.java)
        link("debug", DebugActivity::class.java)
        link("setup", SetupActivity::class.java)
        findPreference<Preference>("clear_history")?.setOnPreferenceClickListener {
            requireContext().app.history.clearAll()
            Toast.makeText(requireContext(), R.string.history_cleared, Toast.LENGTH_SHORT).show()
            true
        }
        findPreference<Preference>("polish_enabled")?.summaryProvider = Preference.SummaryProvider<SwitchPreferenceCompat> { p ->
            val model = requireContext().app.models.llmFile()
            when {
                model == null -> "No polish model imported (Models → AI polish). Rules-only until then."
                p.isChecked -> "On · ${model.name}. Falls back to instant rules after 3 s."
                else -> "Off"
            }
        }
    }

    override fun onResume() {
        super.onResume()
        preferenceManager.sharedPreferences?.registerOnSharedPreferenceChangeListener(this)
        findPreference<SwitchPreferenceCompat>(Settings.KEY_BUBBLE)?.isChecked = requireContext().app.settings.bubbleEnabled
    }

    override fun onPause() {
        preferenceManager.sharedPreferences?.unregisterOnSharedPreferenceChangeListener(this)
        super.onPause()
    }

    override fun onSharedPreferenceChanged(prefs: SharedPreferences?, key: String?) {
        val ctx = context ?: return
        when (key) {
            Settings.KEY_LANGUAGE, Settings.KEY_ENGINE, Settings.KEY_POLISH, Settings.KEY_POLISH_GPU -> ctx.app.warmUp()
            Settings.KEY_BUBBLE -> {
                if (ctx.app.settings.bubbleEnabled) {
                    if (AndroidSettings.canDrawOverlays(ctx)) {
                        BubbleService.start(ctx)
                    } else {
                        ctx.app.settings.bubbleEnabled = false
                        findPreference<SwitchPreferenceCompat>(Settings.KEY_BUBBLE)?.isChecked = false
                        Toast.makeText(ctx, R.string.bubble_no_overlay, Toast.LENGTH_LONG).show()
                        SystemSetup.openOverlaySettings(ctx)
                    }
                } else {
                    BubbleService.stop(ctx)
                }
            }
            Settings.KEY_BUBBLE_HIDE, Settings.KEY_BUBBLE_MODE -> BubbleService.instance?.refresh()
        }
    }

    private fun link(key: String, activity: Class<*>) {
        findPreference<Preference>(key)?.intent = Intent(requireContext(), activity)
    }
}

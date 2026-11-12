package dev.offline.voicetype.ui

import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.offline.voicetype.R

/** Plain-language explanation shown BEFORE sending the user to the Accessibility settings. */
class AccessibilityExplainerActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_explainer)
        findViewById<TextView>(R.id.body).text = getText(R.string.explainer_body)
        findViewById<Button>(R.id.open).setOnClickListener { SystemSetup.openAccessibilitySettings(this) }
        // App info is where "Allow restricted settings" lives on Android 13+.
        findViewById<Button>(R.id.app_info).apply {
            setText(R.string.explainer_app_info)
            setOnClickListener { SystemSetup.openAppDetails(this@AccessibilityExplainerActivity) }
        }
    }

    override fun onResume() {
        super.onResume()
        if (SystemSetup.isAccessibilityEnabled(this)) finish()
    }
}

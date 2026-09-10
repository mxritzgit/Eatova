package com.eatova.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Public rationale entry point; never opens authenticated user data. */
class HealthPrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.health_connect_title)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        content.addView(TextView(this).apply {
            text = getString(R.string.health_connect_rationale)
            textSize = 18f
        })
        content.addView(Button(this).apply {
            text = getString(R.string.health_connect_privacy)
            setOnClickListener {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://eatova.de/datenschutz")))
                } catch (_: Exception) {
                    // Keep the rationale visible when no browser is installed.
                }
            }
        })
        content.addView(Button(this).apply {
            text = getString(R.string.health_connect_close)
            setOnClickListener { finish() }
        })
        setContentView(ScrollView(this).apply { addView(content) })
    }
}

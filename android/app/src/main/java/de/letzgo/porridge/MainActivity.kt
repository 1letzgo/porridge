package de.letzgo.porridge

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import de.letzgo.porridge.data.LinkImport
import de.letzgo.porridge.ui.AppRoot
import de.letzgo.porridge.ui.PorridgeTheme
import de.letzgo.porridge.ui.SharedLinks

/** iOS: `PorridgeApp` / `RootView`; nimmt auch geteilte Links an (iOS: Share-Extension `PorridgeShare`). */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent { PorridgeTheme { AppRoot() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        LinkImport.webAddress(text)?.let { SharedLinks.pending.value = it }
    }
}

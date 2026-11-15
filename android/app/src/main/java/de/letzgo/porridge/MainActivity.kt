package de.letzgo.porridge

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import de.letzgo.porridge.data.ShareImport
import de.letzgo.porridge.ui.AppRoot
import de.letzgo.porridge.ui.PorridgeTheme
import de.letzgo.porridge.ui.SharedLinks

/** iOS: `PorridgeApp` / `RootView`; nimmt auch Geteiltes an (Links, Text, Bilder, PDFs, Dateien, Audio) (iOS: Share-Extension `PorridgeShare`). */
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
        ShareImport.read(intent)?.let { SharedLinks.pending.value = it }
        // Derselbe Intent kommt nach einer Drehung wieder: Er ist erledigt.
        intent?.action = Intent.ACTION_MAIN
    }
}

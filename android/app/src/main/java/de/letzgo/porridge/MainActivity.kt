package de.letzgo.porridge

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import de.letzgo.porridge.ui.AppRoot
import de.letzgo.porridge.ui.PorridgeTheme

/** iOS: `PorridgeApp` / `ContentView`. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { PorridgeTheme { AppRoot() } }
    }
}

package de.letzgo.porridge.ui.onboarding

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.R
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.ml.ModelManager
import de.letzgo.porridge.ml.ModelState
import de.letzgo.porridge.ml.SpeechModel
import de.letzgo.porridge.ui.Brand
import kotlinx.coroutines.launch

/** iOS: `OnboardingView` (App/OnboardingView.swift) — Willkommen, Mikrofon, Sprachmodell. */
@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    var step by remember { mutableStateOf(0) }
    val coroutines = rememberCoroutineScope()
    val asr by ModelManager.state(SpeechModel.pack).collectAsState()
    val mic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { step = 2 }
    fun finish() { Prefs.set(Keys.ONBOARDING_DONE, true); onDone() }

    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding().navigationBarsPadding().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Spacer(Modifier.weight(1f))
        when (step) {
            0 -> {
                Image(painterResource(R.drawable.ic_launcher_fore), null, Modifier.size(120.dp).clip(RoundedCornerShape(28.dp)))
                Text("Porridge", style = MaterialTheme.typography.headlineLarge)
                Text("Record meetings and notes, transcribe and summarize them – on your phone.", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            1 -> {
                Icon(Icons.Filled.Mic, null, tint = Brand.sky, modifier = Modifier.size(64.dp))
                Text("Microphone", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
                Text("Porridge needs the microphone to record. Recordings stay on this phone.", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> {
                Icon(Icons.Filled.Download, null, tint = Brand.sky, modifier = Modifier.size(64.dp))
                Text("Speech Model", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
                Text("Parakeet v3 recognizes 25 European languages on your phone. It is downloaded once (${SpeechModel.pack.sizeText}); Wi-Fi is recommended.", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                when (val s = asr) {
                    is ModelState.Downloading -> LinearProgressIndicator(progress = { s.fraction }, modifier = Modifier.fillMaxWidth(), color = Brand.sky)
                    is ModelState.Failed -> Text(s.message, color = Brand.danger)
                    else -> Unit
                }
            }
        }
        Spacer(Modifier.weight(1f))
        val ready = asr == ModelState.Installed || asr == ModelState.Ready
        Button(
            onClick = {
                when (step) {
                    0 -> step = 1
                    1 -> mic.launch(Manifest.permission.RECORD_AUDIO)
                    else -> if (ready) finish() else coroutines.launch { ModelManager.download(SpeechModel.pack) }
                }
            },
            enabled = !(step == 2 && asr is ModelState.Downloading),
            modifier = Modifier.fillMaxWidth().height(52.dp), colors = ButtonDefaults.buttonColors(containerColor = Brand.sky),
        ) { Text(when (step) { 0 -> "Continue"; 1 -> "Allow Microphone"; else -> if (ready) "Start" else "Download" }) }
        if (step == 2 && !ready) TextButton(onClick = ::finish) { Text("Later") }
    }
}

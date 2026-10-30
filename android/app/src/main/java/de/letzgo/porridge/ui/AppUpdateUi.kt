package de.letzgo.porridge.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import de.letzgo.porridge.data.AppUpdate
import kotlinx.coroutines.launch
import java.io.File

/**
 * iOS (Mac): Update-Hinweis aus `AppUpdate`. Lädt die APK in der App (Fortschritt und Prüfsumme) und übergibt
 * sie dem Paketinstaller. Fehlt die Freigabe „Install unknown apps“, führt der Dialog dorthin und installiert,
 * sobald man zurückkommt (wie stede/abstand).
 */
@Composable
fun AppUpdateDialog(release: AppUpdate.Release, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var progress by remember { mutableStateOf<Float?>(null) }
    var downloading by remember { mutableStateOf(false) }
    var file by remember { mutableStateOf<File?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var waitingForPermission by remember { mutableStateOf(false) }

    fun installOrAsk(apk: File) {
        if (AppUpdate.canInstall(context)) {
            waitingForPermission = false
            AppUpdate.install(context, apk)
        } else {
            waitingForPermission = true
            AppUpdate.openInstallPermission(context)
        }
    }

    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(waitingForPermission) {
        if (!waitingForPermission) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            file?.let { if (AppUpdate.canInstall(context)) installOrAsk(it) }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!downloading) onDismiss() },
        title = { Text("Porridge ${release.version} is available") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (release.notes.isNotEmpty()) Text(release.notes, style = MaterialTheme.typography.bodyMedium)
                when {
                    error != null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                    downloading -> {
                        Text("Downloading…", style = MaterialTheme.typography.bodyMedium)
                        progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
                            ?: LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    }
                    waitingForPermission -> Text("Allow Porridge to install apps in the Android settings, then come back.")
                    file != null -> Text("Downloaded. Android will ask whether to install the new version.")
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !downloading,
                onClick = {
                    val apk = file
                    if (apk != null) installOrAsk(apk) else scope.launch {
                        downloading = true
                        error = null
                        progress = null
                        runCatching { AppUpdate.download(context, release) { progress = it } }
                            .onSuccess { file = it; installOrAsk(it) }
                            .onFailure { error = it.message ?: "The new version could not be downloaded." }
                        downloading = false
                    }
                },
            ) { Text(if (file != null) "Install" else if (error != null) "Try Again" else "Update") }
        },
        dismissButton = {
            if (!downloading) TextButton(onClick = {
                if (file == null) AppUpdate.skip(release)
                onDismiss()
            }) { Text("Later") }
        },
    )
}

/** Prüft beim Start (höchstens alle sechs Stunden) und zeigt den Hinweis. */
@Composable
fun AppUpdateCheck() {
    val context = LocalContext.current
    var release by remember { mutableStateOf<AppUpdate.Release?>(null) }
    LaunchedEffect(Unit) { release = AppUpdate.checkOnLaunch(context) }
    release?.let { AppUpdateDialog(it) { release = null } }
}

package de.letzgo.porridge.ui.plaud

import android.Manifest
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.plaud.PlaudImporter
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.EmptyState
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** iOS: `PlaudImportSheet` — listet die Aufnahmen auf einem Plaud-Recorder und übernimmt die gewählten als Notizen. */
@Composable
fun PlaudImportScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    val importer = remember { PlaudImporter(context) }
    val signedIn by importer.signedIn.collectAsState()
    val recordings by importer.recordings.collectAsState()
    val working by importer.isWorking.collectAsState()
    val status by importer.status.collectAsState()
    val importing by importer.importingId.collectAsState()
    val progress by importer.progress.collectAsState()
    val error by importer.errorMessage.collectAsState()
    var showLogin by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var lastImported by remember { mutableStateOf<String?>(null) }
    val coroutines = rememberCoroutineScope()
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { coroutines.launch { importer.refresh() } }
    fun refresh() {
        val needed = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        permissions.launch(needed)
    }
    LaunchedEffect(signedIn) { if (signedIn) refresh() }
    DisposableEffect(Unit) { onDispose { importer.disconnect() } }
    BackHandler(enabled = importing == null && !showLogin) { onBack() }

    if (showLogin) {
        PlaudLoginScreen(onToken = { token, refresh -> showLogin = false; importer.signIn(token, refresh) }, onCancel = { showLogin = false })
        return
    }
    val newOnes = recordings.filter { !it.imported }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, enabled = importing == null) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Close", tint = Brand.navy) }
            Text("Plaud", style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold), modifier = Modifier.weight(1f))
            if (signedIn) Box {
                IconButton(onClick = { menu = true }, enabled = importing == null) { Icon(Icons.Filled.MoreVert, "More", tint = Brand.navy) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Reload") }, onClick = { menu = false; refresh() })
                    DropdownMenuItem(text = { Text("Sign Out", color = Brand.danger) }, onClick = { menu = false; importer.signOut() })
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            when {
                !signedIn -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    EmptyState("Plaud Recorder", "Sign in to Plaud once. After that the recordings come straight from the recorder over Bluetooth.", Icons.Filled.GraphicEq)
                    Button(onClick = { showLogin = true }, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky), modifier = Modifier.padding(horizontal = 40.dp).fillMaxWidth()) { Text("Sign In to Plaud") }
                }
                recordings.isEmpty() -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(24.dp)) {
                    if (working) {
                        CircularProgressIndicator(color = Brand.sky)
                        Text(status.ifEmpty { "Connecting …" }, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                        Text("Wake the recorder with its button. Close the Plaud app if it is open.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    } else {
                        EmptyState(if (status.isEmpty()) "No Recorder Found" else "Nothing to Import", status.ifEmpty { "Wake the recorder with its button and try again." }, Icons.Filled.GraphicEq)
                        Button(onClick = ::refresh, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky)) { Text("Try Again") }
                    }
                }
                else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(recordings, key = { it.sessionId }) { rec ->
                        Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(SimpleDateFormat("d MMM yyyy, HH:mm", Locale.getDefault()).format(Date(rec.date)), fontWeight = FontWeight.SemiBold, color = Brand.navy)
                                    Text(android.text.format.Formatter.formatShortFileSize(context, rec.size), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (importing == rec.sessionId) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), color = Brand.sky)
                                }
                                when {
                                    importing == rec.sessionId -> OutlinedButton(onClick = { importer.cancelImport() }) { Text("Stop") }
                                    rec.imported -> Icon(Icons.Filled.CheckCircle, "Imported", tint = Brand.sky)
                                    else -> OutlinedButton(enabled = importing == null, onClick = {
                                        coroutines.launch { importer.importRecording(rec)?.let { lastImported = PlaudImporter.addNote(it).id } }
                                    }) { Text("Import") }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (status.isNotEmpty() && importing != null) Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))
        if (newOnes.isNotEmpty()) Button(
            onClick = { coroutines.launch { for (rec in newOnes) { val audio = importer.importRecording(rec) ?: break; lastImported = PlaudImporter.addNote(audio).id } } },
            enabled = importing == null, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky),
            modifier = Modifier.fillMaxWidth().padding(16.dp).navigationBarsPadding(),
        ) { Text(if (newOnes.size == 1) "Import 1 Recording" else "Import ${newOnes.size} Recordings") }
        lastImported?.let { id -> if (importing == null) TextButton(onClick = { onOpen(id) }, modifier = Modifier.align(Alignment.CenterHorizontally).navigationBarsPadding()) { Text("Open Imported Note") } }
    }
    error?.let { AlertDialog(onDismissRequest = { importer.errorMessage.value = null }, title = { Text("Plaud") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { importer.errorMessage.value = null }) { Text("OK") } }) }
}

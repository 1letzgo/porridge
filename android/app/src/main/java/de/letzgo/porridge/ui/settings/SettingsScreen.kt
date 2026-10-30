package de.letzgo.porridge.ui.settings

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.BuildConfig
import de.letzgo.porridge.PorridgeApplication
import de.letzgo.porridge.cloud.AIProvider
import de.letzgo.porridge.cloud.CloudLLM
import de.letzgo.porridge.data.AppUpdate
import de.letzgo.porridge.data.Backup
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SummaryBilling
import de.letzgo.porridge.data.transcriptionLanguages
import de.letzgo.porridge.ml.Diarizer
import de.letzgo.porridge.ml.LocalLLM
import de.letzgo.porridge.ml.LocalModel
import de.letzgo.porridge.ml.ModelManager
import de.letzgo.porridge.ml.ModelPack
import de.letzgo.porridge.ml.ModelState
import de.letzgo.porridge.ml.SpeechModel
import de.letzgo.porridge.ml.TextEmbedder
import de.letzgo.porridge.ml.VoiceProfiles
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.AppUpdateDialog
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.notes.TextPrompt
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** iOS: `SettingsView` (Views/Settings/SettingsView.swift) — Karten wie auf iOS; statt iCloud eine Sicherung. */
@Composable
fun SettingsScreen(onBack: () -> Unit, onPlaud: () -> Unit) {
    BackHandler { onBack() }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Brand.navy) }
            Text("Settings", style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold))
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            YouCard()
            TranscriptionCard()
            VoicesCard()
            ModelsCard()
            SummaryCard()
            Card("Plaud") { Row(verticalAlignment = Alignment.CenterVertically) { Text("Import Recordings", Modifier.weight(1f), fontWeight = FontWeight.SemiBold); Pill("Open", onPlaud) } }
            BackupCard()
            AboutCard()
        }
    }
}

@Composable
private fun Card(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), color = Brand.navy, modifier = Modifier.padding(start = 4.dp))
        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 1.dp) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        }
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp)) }
    }
}

@Composable
private fun Pill(label: String, onClick: () -> Unit, enabled: Boolean = true) =
    Button(onClick = onClick, enabled = enabled, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky.copy(alpha = 0.18f), contentColor = Brand.navy), shape = RoundedCornerShape(50)) { Text(label) }

@Composable
private fun ToggleRow(label: String, key: String) {
    var on by remember { mutableStateOf(Prefs.bool(key)) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
        Switch(checked = on, onCheckedChange = { on = it; Prefs.set(key, it) }, colors = SwitchDefaults.colors(checkedTrackColor = Brand.sky))
    }
}

@Composable
private fun <T> Picker(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
        Column {
            TextButton(onClick = { open = true }) { Text(options.firstOrNull { it.first == selected }?.second ?: "") }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for ((value, title) in options) DropdownMenuItem(text = { Text(title) }, onClick = { open = false; onSelect(value) })
            }
        }
    }
}

@Composable
private fun TranscriptionCard() = Card("Transcription") {
    var language by remember { mutableStateOf(Prefs.language) }
    Picker("Language", transcriptionLanguages, language) { language = it; Prefs.set(Keys.LANGUAGE, it) }
    HorizontalDivider()
    ToggleRow("Detect Speakers", Keys.SPEAKER_DETECTION)
}

@Composable
private fun VoicesCard() {
    val profiles by PorridgeDatabase.shared.voiceProfiles().observeAll().collectAsState(initial = emptyList())
    val coroutines = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<de.letzgo.porridge.model.VoiceProfile?>(null) }
    var forgetting by remember { mutableStateOf<de.letzgo.porridge.model.VoiceProfile?>(null) }
    Card("Voices", footer = "Naming a speaker teaches Porridge the voice. Only a voice print is stored, never audio.") {
        ToggleRow("Recognize Voices", Keys.VOICE_RECOGNITION)
        for (profile in profiles) {
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(profile.name, fontWeight = FontWeight.SemiBold)
                    Text("${profile.seconds.toInt()} s of speech", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = { renaming = profile }) { Text("Rename") }
                IconButton(onClick = { forgetting = profile }) { Icon(Icons.Outlined.Delete, "Forget Voice", tint = Brand.danger) }
            }
        }
    }
    renaming?.let { p -> TextPrompt("Rename Voice", p.name, "Save", { renaming = null }) { name -> renaming = null; coroutines.launch { VoiceProfiles().rename(p, name) } } }
    forgetting?.let { p ->
        AlertDialog(
            onDismissRequest = { forgetting = null }, title = { Text("Forget this voice?") }, text = { Text("Names already given in meetings stay.") },
            confirmButton = { TextButton(onClick = { forgetting = null; coroutines.launch { VoiceProfiles().delete(p) } }) { Text("Forget Voice", color = Brand.danger) } },
            dismissButton = { TextButton(onClick = { forgetting = null }) { Text("Cancel") } },
        )
    }
}

/** Eine Zeile je Modell: herunterladen, Fortschritt, löschen. */
@Composable
private fun ModelRow(pack: ModelPack, subtitle: String, unload: () -> Unit) {
    val state by ModelManager.state(pack).collectAsState()
    val coroutines = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(pack.displayName, fontWeight = FontWeight.SemiBold)
            Text("$subtitle · ${pack.sizeText}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            when (val s = state) {
                is ModelState.Downloading -> LinearProgressIndicator(progress = { s.fraction }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), color = Brand.sky)
                is ModelState.Failed -> Text(s.message, style = MaterialTheme.typography.labelSmall, color = Brand.danger)
                else -> Unit
            }
        }
        when (state) {
            ModelState.NotInstalled, is ModelState.Failed -> Pill("Download", { coroutines.launch { ModelManager.download(pack) } })
            is ModelState.Downloading, ModelState.Loading -> CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = Brand.sky)
            ModelState.Installed, ModelState.Ready -> {
                Icon(Icons.Filled.CheckCircle, "Installed", tint = Brand.sky)
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.Delete, "Delete", tint = Brand.danger) }
            }
        }
    }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false }, title = { Text("Delete ${pack.displayName}?") }, text = { Text("You can download it again at any time.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; ModelManager.delete(pack, unload) }) { Text("Delete", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun ModelsCard() = Card("On-Device Models", footer = "Models run on this phone. Nothing leaves it.") {
    ModelRow(SpeechModel.pack, "Speech recognition · 0.6B") { SpeechModel.release() }
    HorizontalDivider()
    ModelRow(Diarizer.pack, "pyannote") { Diarizer.release() }
    HorizontalDivider()
    ModelRow(TextEmbedder.pack, "Finds notes by meaning in chat and search") {}
}

/** iOS: `youCard` — wer der Nutzer ist: seine Aufgaben stehen unter „Mine“, die Zusammenfassungen nennen ihn. */
@Composable
private fun YouCard() {
    var name by remember { mutableStateOf(Prefs.string(Keys.MY_NAME).orEmpty()) }
    Card("You", footer = "Tasks given to this name show under Mine. Separate other spellings with commas, e.g. “Anna, Anna Berg”.") {
        OutlinedTextField(name, { name = it; Prefs.set(Keys.MY_NAME, it) }, label = { Text("Your Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun SummaryCard() {
    val context = LocalContext.current
    val coroutines = rememberCoroutineScope()
    var billing by remember { mutableStateOf(Prefs.billing) }
    var local by remember { mutableStateOf(LocalModel.of(Prefs.string(Keys.LOCAL_MODEL))) }
    var provider by remember { mutableStateOf(AIProvider.current) }
    var key by remember(provider) { mutableStateOf(provider.apiKey) }
    var baseURL by remember { mutableStateOf(AIProvider.customBaseURL) }
    var model by remember(provider) { mutableStateOf(provider.model) }
    var models by remember(provider) { mutableStateOf(provider.suggestedModels) }
    var loadError by remember { mutableStateOf<String?>(null) }
    Card("AI Summary", footer = if (billing == SummaryBilling.BYOK) "Your key is stored on this phone, encrypted. One key per service." else "${LocalModel.totalMemoryGB(context).let { "%.0f".format(it) }} GB memory: ${LocalModel.recommended(context).displayName} recommended.") {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SummaryBilling.entries.forEachIndexed { i, b ->
                SegmentedButton(
                    selected = billing == b, onClick = { billing = b; Prefs.set(Keys.BILLING, b.raw) }, shape = SegmentedButtonDefaults.itemShape(i, 2), icon = {},
                    colors = SegmentedButtonDefaults.colors(activeContainerColor = Brand.sky.copy(alpha = 0.18f), activeContentColor = Brand.navy),
                ) { Text(b.label) }
            }
        }
        if (billing == SummaryBilling.LOCAL) {
            Picker("Summary Model", LocalModel.entries.map { it to it.displayName }, local) {
                local = it
                Prefs.set(Keys.LOCAL_MODEL, it.raw)
                PorridgeApplication.selectLocalModel()
            }
            for (m in LocalModel.entries) {
                HorizontalDivider()
                ModelRow(m.pack, "Summaries on your device") { coroutines.launch { LocalLLM.of(m).unload() } }
            }
        } else {
            Picker("Provider", AIProvider.entries.map { it to it.label }, provider) { provider = it; AIProvider.current = it }
            if (provider == AIProvider.CUSTOM) OutlinedTextField(baseURL, { baseURL = it; AIProvider.customBaseURL = it }, label = { Text("Server address") }, placeholder = { Text("http://192.168.1.5:11434/v1") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(
                key, { key = it; provider.apiKey = it }, label = { Text(if (provider == AIProvider.CUSTOM) "Custom server key (optional)" else "${provider.label} API Key") },
                singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(),
            )
            Picker("Model", models.map { it.first to it.second }.let { list -> if (list.none { it.first == model } && model.isNotEmpty()) list + (model to model) else list }, model) { model = it; provider.model = it }
            OutlinedTextField(model, { model = it; provider.model = it }, label = { Text("Model ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            if (provider.canListModels) OutlinedButton(enabled = key.isNotEmpty(), onClick = {
                coroutines.launch {
                    runCatching { CloudLLM.models(provider, key) }.onSuccess { ids -> loadError = null; if (ids.isNotEmpty()) models = ids.map { it to it } }.onFailure { loadError = it.message }
                }
            }) { Text("Load Models") }
            loadError?.let { Text(it, color = Brand.danger, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun BackupCard() {
    val context = LocalContext.current
    val coroutines = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri != null) coroutines.launch { message = runCatching { Backup.export(context, uri) }.fold({ "Saved ${it.notes} notes and ${it.recordings} recordings." }, { "Backup failed: ${it.message}" }) }
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) coroutines.launch { message = runCatching { Backup.import(context, uri) }.fold({ "Restored ${it.notes} notes and ${it.recordings} recordings." }, { "Restore failed: ${it.message}" }) }
    }
    Card("Backup", footer = message ?: "Notes, voices, tasks and recordings in one file. Restoring keeps the newer version of each note.") {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Pill("Back Up", { exporter.launch("porridge-backup-${SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())}.zip") })
            Pill("Restore", { importer.launch(arrayOf("application/zip", "application/octet-stream")) })
        }
    }
}

@Composable
private fun AboutCard() {
    val coroutines = rememberCoroutineScope()
    var result by remember { mutableStateOf<String?>(null) }
    var release by remember { mutableStateOf<AppUpdate.Release?>(null) }
    var checking by remember { mutableStateOf(false) }
    Card("About", footer = "Speech recognition: sherpa-onnx · NVIDIA Parakeet (CC-BY-4.0) · pyannote · llama.cpp · Qwen3") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Version", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (BuildConfig.SIDELOAD) {
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Updates", fontWeight = FontWeight.SemiBold)
                    result?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                if (checking) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = Brand.sky)
                else Pill("Check Now", {
                    checking = true
                    coroutines.launch {
                        runCatching { AppUpdate.checkManually() }
                            .onSuccess { if (it == null) result = "Porridge ${BuildConfig.VERSION_NAME} is up to date." else release = it }
                            .onFailure { result = "Could not check: ${it.message}" }
                        checking = false
                    }
                })
            }
        }
    }
    release?.let { AppUpdateDialog(it) { release = null } }
}

package de.letzgo.porridge.ui.settings

import de.letzgo.porridge.ui.components.pageTransition
import androidx.compose.animation.AnimatedContent
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.selection.toggleable
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.delay
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
import de.letzgo.porridge.logic.SummaryTemplate
import de.letzgo.porridge.BuildConfig
import de.letzgo.porridge.PorridgeApplication
import de.letzgo.porridge.cloud.AIProvider
import de.letzgo.porridge.cloud.CloudLLM
import de.letzgo.porridge.cloud.SummaryModel
import de.letzgo.porridge.data.AppUpdate
import de.letzgo.porridge.data.Backup
import de.letzgo.porridge.data.Me
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.outlined.AccountCircle
import de.letzgo.porridge.sync.NextcloudLogin
import de.letzgo.porridge.sync.NextcloudSync
import de.letzgo.porridge.sync.SyncMode
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
import de.letzgo.porridge.ml.VoiceProfiles
import de.letzgo.porridge.plaud.PlaudAccount
import de.letzgo.porridge.plaud.PlaudImporter
import de.letzgo.porridge.ui.components.ChromeBar
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Settings
import de.letzgo.porridge.ui.plaud.PlaudLoginScreen
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.AppUpdateDialog
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.notes.TextPrompt
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/** iOS: `SettingsView` (Views/Settings/SettingsView.swift) — Karten wie auf iOS; statt iCloud eine Sicherung. */
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    // Hier, damit die Seite nach einem Unterbildschirm an derselben Stelle steht.
    val pageScroll = rememberScrollState()
    var subpage by remember { mutableStateOf(SettingsSubpage.NONE) }
    AnimatedContent(subpage, transitionSpec = { pageTransition(forward = targetState != SettingsSubpage.NONE) }, label = "settings") { shown ->
        when (shown) {
            SettingsSubpage.ACKNOWLEDGEMENTS -> AcknowledgementsScreen { subpage = SettingsSubpage.NONE }
            SettingsSubpage.VOICES -> VoicesScreen { subpage = SettingsSubpage.NONE }
            SettingsSubpage.NONE -> SettingsPage(pageScroll, onBack, onVoices = { subpage = SettingsSubpage.VOICES }, onAcknowledgements = { subpage = SettingsSubpage.ACKNOWLEDGEMENTS })
        }
    }
}

private enum class SettingsSubpage { NONE, VOICES, ACKNOWLEDGEMENTS }

@Composable
private fun SettingsPage(pageScroll: androidx.compose.foundation.ScrollState, onBack: () -> Unit, onVoices: () -> Unit, onAcknowledgements: () -> Unit) {
    val context = LocalContext.current
    var plaudSignedIn by remember { mutableStateOf(PlaudAccount.load().userToken != null) }
    var showPlaudLogin by remember { mutableStateOf(false) }
    if (showPlaudLogin) return PlaudLoginScreen(
        onToken = { token, refresh -> PlaudImporter(context).signIn(token, refresh); plaudSignedIn = true; showPlaudLogin = false },
        onCancel = { showPlaudLogin = false },
    )
    BackHandler { onBack() }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding()) {
        ChromeBar("Settings", Icons.Filled.Settings, onBack = onBack) {}
        Column(Modifier.fillMaxSize().verticalScroll(pageScroll).padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            YouCard()
            TranscriptionCard()
            VoicesCard(onOpen = onVoices)
            ModelsCard()
            SummaryCard()
            PlaudCard(plaudSignedIn, onSignIn = { showPlaudLogin = true }, onSignOut = { PlaudAccount.clear(); plaudSignedIn = false })
            SyncCard()
            BackupCard()
            AboutCard()
            Card("Acknowledgements") { Row(verticalAlignment = Alignment.CenterVertically) { Text("Open Source Licenses", Modifier.weight(1f), fontWeight = FontWeight.SemiBold); Pill("Open", { onAcknowledgements() }) } }
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
private fun Pill(label: String, onClick: () -> Unit, enabled: Boolean = true, destructive: Boolean = false) =
    Button(onClick = onClick, enabled = enabled, colors = ButtonDefaults.buttonColors(containerColor = (if (destructive) Brand.danger else Brand.sky).copy(alpha = 0.18f), contentColor = if (destructive) Brand.dangerText else Brand.navy), shape = RoundedCornerShape(50)) { Text(label) }

@Composable
private fun ToggleRow(label: String, key: String) {
    var on by remember { mutableStateOf(Prefs.bool(key)) }
    Row(Modifier.fillMaxWidth().toggleable(value = on, role = Role.Switch) { on = it; Prefs.set(key, it) }, verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
        Switch(checked = on, onCheckedChange = null, colors = SwitchDefaults.colors(checkedTrackColor = Brand.sky))
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
    HorizontalDivider()
    ToggleRow("Record New Notes Automatically", Keys.RECORDS_NEW_NOTES)
}

@Composable
private fun VoicesCard(onOpen: () -> Unit) {
    val profiles by PorridgeDatabase.shared.voiceProfiles().observeAll().collectAsState(initial = emptyList())
    Card("Voices") {
        ToggleRow("Recognize Voices", Keys.VOICE_RECOGNITION)
        HorizontalDivider()
        Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Known Voices", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Text("${profiles.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** iOS: `VoicesView` — die gelernten Stimmen: welche die eigene ist, wie sie heißen, und eine vergessen. */
@Composable
private fun VoicesScreen(onBack: () -> Unit) {
    val profiles by PorridgeDatabase.shared.voiceProfiles().observeAll().collectAsState(initial = emptyList())
    val coroutines = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<de.letzgo.porridge.model.VoiceProfile?>(null) }
    var forgetting by remember { mutableStateOf<de.letzgo.porridge.model.VoiceProfile?>(null) }
    // Die eigene Stimme oben.
    var myVoice by remember { mutableStateOf(Me.voiceID) }
    BackHandler { onBack() }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding()) {
        ChromeBar("Known Voices", Icons.Filled.Groups, onBack = onBack) {}
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (profiles.isNotEmpty()) Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 1.dp) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    profiles.sortedBy { if (it.id == myVoice) 0 else 1 }.forEachIndexed { index, profile ->
                        val isMe = profile.id == myVoice
                        if (index > 0) HorizontalDivider()
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(if (isMe) "${profile.name} (me)" else profile.name, fontWeight = FontWeight.SemiBold)
                                Text("${profile.seconds.toInt()} s of speech", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { Me.setVoice(if (isMe) null else profile); myVoice = Me.voiceID }) {
                                Icon(
                                    if (isMe) Icons.Filled.AccountCircle else Icons.Outlined.AccountCircle,
                                    if (isMe) "Not Me" else "This Is Me", tint = if (isMe) Brand.task else Brand.navy,
                                )
                            }
                            TextButton(onClick = { renaming = profile }) { Text("Rename") }
                            IconButton(onClick = { forgetting = profile }) { Icon(Icons.Outlined.Delete, "Forget Voice", tint = Brand.dangerText) }
                        }
                    }
                }
            }
            if (profiles.isEmpty()) Text(
                "No voices yet. Naming a speaker in a meeting teaches Porridge the voice.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    renaming?.let { p -> TextPrompt("Rename Voice", p.name, "Save", { renaming = null }) { name -> renaming = null; coroutines.launch { VoiceProfiles().rename(p, name) } } }
    forgetting?.let { p ->
        AlertDialog(
            onDismissRequest = { forgetting = null }, title = { Text("Forget Voice?") }, text = { Text("Names already given in meetings stay.") },
            confirmButton = { TextButton(onClick = { forgetting = null; coroutines.launch { VoiceProfiles().delete(p) } }) { Text("Forget Voice", color = Brand.dangerText) } },
            dismissButton = { TextButton(onClick = { forgetting = null }) { Text("Cancel") } },
        )
    }
}

/** Eine Zeile je Modell: herunterladen, Fortschritt, löschen. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ModelRow(pack: ModelPack, subtitle: String, unload: () -> Unit) {
    val state by ModelManager.state(pack).collectAsState()
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmCancel by remember { mutableStateOf(false) }
    val downloading = state is ModelState.Downloading
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = if (downloading) {
            Modifier.combinedClickable(onLongClickLabel = "Cancel Download", onLongClick = { confirmCancel = true }, onClick = {})
        } else {
            Modifier
        },
    ) {
        Column(Modifier.weight(1f)) {
            Text(pack.displayName, fontWeight = FontWeight.SemiBold)
            Text(
                if (downloading) "Press and hold to cancel" else "$subtitle · ${pack.sizeText}",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            when (val s = state) {
                is ModelState.Downloading -> LinearProgressIndicator(progress = { s.fraction }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), color = Brand.sky)
                is ModelState.Failed -> Text(s.message, style = MaterialTheme.typography.labelSmall, color = Brand.dangerText)
                else -> Unit
            }
        }
        when (state) {
            ModelState.NotInstalled, is ModelState.Failed -> Pill("Download", { ModelManager.startDownload(pack) })
            is ModelState.Downloading, ModelState.Loading -> CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = Brand.sky)
            ModelState.Installed, ModelState.Ready -> {
                Icon(Icons.Filled.CheckCircle, "Installed", tint = Brand.skyText)
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.Delete, "Delete", tint = Brand.dangerText) }
            }
        }
    }
    if (confirmCancel && downloading) AlertDialog(
        onDismissRequest = { confirmCancel = false }, title = { Text("Cancel Download of ${pack.displayName}?") },
        text = { Text("What has been downloaded so far will be deleted.") },
        confirmButton = { TextButton(onClick = { confirmCancel = false; ModelManager.cancelDownload(pack) }) { Text("Cancel Download", color = Brand.dangerText) } },
        dismissButton = { TextButton(onClick = { confirmCancel = false }) { Text("Keep Downloading") } },
    )
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false }, title = { Text("Delete ${pack.displayName}?") }, text = { Text("You can download it again at any time.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; ModelManager.delete(pack, unload) }) { Text("Delete", color = Brand.dangerText) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun ModelsCard() = Card("On-Device Models") {
    ModelRow(SpeechModel.pack, "Speech recognition · 0.6B") { SpeechModel.release() }
    HorizontalDivider()
    ModelRow(Diarizer.pack, "pyannote") { Diarizer.release() }
}

/** iOS: `youCard` — wer der Nutzer ist: die Zusammenfassungen nennen ihn. */
@Composable
private fun YouCard() {
    var name by remember { mutableStateOf(Prefs.string(Keys.MY_NAME).orEmpty()) }
    Card("You") {
        OutlinedTextField(name, { name = it; Prefs.set(Keys.MY_NAME, it); NextcloudSync.syncSoon() }, label = { Text("Your Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun SummaryCard() {
    val coroutines = rememberCoroutineScope()
    var editTemplates by remember { mutableStateOf(false) }
    var addModel by remember { mutableStateOf(false) }
    var default by remember { mutableStateOf(SummaryModel.current) }
    var external by remember { mutableStateOf(SummaryModel.external) }
    // Ein Download, der fertig wird, oder ein gelöschtes Modell ändern, was wählbar ist.
    val states = LocalModel.entries.map { ModelManager.state(it.pack).collectAsState().value }
    fun refresh() {
        SummaryModel.repairCurrent()
        default = SummaryModel.current
        external = SummaryModel.external
    }
    LaunchedEffect(states) { refresh() }
    Card("AI Summary") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Custom Templates", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Pill("Edit", { editTemplates = true })
        }
        HorizontalDivider()
        val available = SummaryModel.available
        if (available.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Default Model", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                Text("None added", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            Picker("Default Model", available.map { it to it.name }, default) {
                default = it
                SummaryModel.current = it
            }
        }
        LocalModel.entries.forEachIndexed { index, m ->
            // Noch nicht Geladenes steht im Hinzufügen-Fenster.
            if (states[index] != ModelState.NotInstalled && states[index] !is ModelState.Failed) {
                HorizontalDivider()
                ModelRow(m.pack, "On this device") { coroutines.launch { LocalLLM.of(m).unload() } }
            }
        }
        for (model in external) {
            var confirmRemove by remember(model) { mutableStateOf(false) }
            if (confirmRemove) AlertDialog(
                onDismissRequest = { confirmRemove = false }, title = { Text("Remove ${model.name}?") },
                text = { Text("You can add it again at any time.") },
                confirmButton = { TextButton(onClick = { confirmRemove = false; SummaryModel.remove(model); refresh() }) { Text("Remove", color = Brand.dangerText) } },
                dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel") } },
            )
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(model.name, fontWeight = FontWeight.SemiBold)
                    Text(model.place, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Icon(Icons.Filled.CheckCircle, "Added", tint = Brand.skyText)
                IconButton(onClick = { confirmRemove = true }) { Icon(Icons.Outlined.Delete, "Remove", tint = Brand.dangerText) }
            }
        }
        HorizontalDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Add Model", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Pill("Add", { addModel = true })
        }
    }
    if (editTemplates) CustomTemplatesDialog { editTemplates = false }
    if (addModel) AddModelSheet(onDismiss = { addModel = false; refresh() })
}

/** iOS: `AddModelSheet` — ein Modell hinzufügen: ein noch nicht geladenes vom Gerät oder eines von einem Cloud-Dienst. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun AddModelSheet(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val coroutines = rememberCoroutineScope()
    var provider by remember { mutableStateOf<AIProvider?>(null) }
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss, sheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val chosen = provider
            if (chosen != null) {
                AddCloudModel(chosen, onBack = { provider = null }, onAdded = onDismiss)
            } else {
                Text("Add Model", style = MaterialTheme.typography.titleLarge)
                Text("On This Device", style = MaterialTheme.typography.labelLarge, color = Brand.skyText)
                val recommended = LocalModel.recommended(context)
                val open = LocalModel.entries.filter { ModelManager.state(it.pack).collectAsState().value.let { s -> s != ModelState.Installed && s != ModelState.Ready } }
                if (open.isEmpty()) Text("All on-device models are added.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                for (m in open) ModelRow(m.pack, if (m == recommended) "Recommended for this device" else "On this device") { coroutines.launch { LocalLLM.of(m).unload() } }
                HorizontalDivider()
                Text("Cloud Service", style = MaterialTheme.typography.labelLarge, color = Brand.skyText)
                for (option in AIProvider.entries) {
                    Row(Modifier.fillMaxWidth().clickable { provider = option }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(option.label, Modifier.weight(1f))
                        Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

/** Der Schlüssel eines Dienstes, einmal für alle seine Modelle, und das Modell, das dazukommt. */
@Composable
private fun AddCloudModel(provider: AIProvider, onBack: () -> Unit, onAdded: () -> Unit) {
    var key by remember { mutableStateOf(provider.apiKey) }
    var baseURL by remember { mutableStateOf(AIProvider.customBaseURL) }
    var model by remember { mutableStateOf(provider.suggestedModels.firstOrNull()?.first.orEmpty()) }
    var models by remember { mutableStateOf(provider.suggestedModels) }
    var loadError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(key) {
        loadError = null
        if (!provider.canListModels || key.isBlank()) return@LaunchedEffect
        delay(600)
        runCatching { CloudLLM.models(provider, key.trim()) }
            .onSuccess { ids ->
                if (ids.isNotEmpty()) {
                    models = ids.map { it to it }
                    if (model !in ids) model = ids.firstOrNull { id -> listOf("haiku", "flash", "mini", "luna", "small").any { id.lowercase().contains(it) } } ?: ids.first()
                }
            }
            .onFailure { if (it !is kotlinx.coroutines.CancellationException) loadError = it.message }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Brand.navy) }
        Text(provider.label, style = MaterialTheme.typography.titleLarge)
    }
    if (provider == AIProvider.CUSTOM) OutlinedTextField(baseURL, { baseURL = it }, label = { Text("Server Address") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(
        key, { key = it }, label = { Text(if (provider.requiresKey) "${provider.label} API Key" else "API Key (optional)") },
        singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(),
    )
    if (models.isNotEmpty()) Picker("Model", models.let { list -> if (list.none { it.first == model } && model.isNotEmpty()) list + (model to model) else list }, model) { model = it }
    OutlinedTextField(model, { model = it }, label = { Text("Model ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    loadError?.let { Text(it, color = Brand.dangerText, style = MaterialTheme.typography.bodySmall) }
    Button(
        enabled = model.isNotBlank() && (if (provider == AIProvider.CUSTOM) baseURL.isNotBlank() else key.isNotBlank()),
        onClick = {
            provider.apiKey = key.trim()
            if (provider == AIProvider.CUSTOM) AIProvider.customBaseURL = baseURL.trim()
            SummaryModel.add(SummaryModel.Cloud(provider, model.trim()))
            SummaryModel.repairCurrent()
            onAdded()
        },
        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Brand.sky.copy(alpha = 0.18f), contentColor = Brand.navy),
    ) { Text("Add Model") }
}

/** iOS: `SummaryTemplatesView` — die eigenen Vorlagen: ein Name und worauf die Zusammenfassung achten soll. */
@Composable
private fun CustomTemplatesDialog(onDismiss: () -> Unit) {
    var templates by remember { mutableStateOf(SummaryTemplate.custom) }
    var editing by remember { mutableStateOf<SummaryTemplate?>(null) }
    var deleting by remember { mutableStateOf<SummaryTemplate?>(null) }
    deleting?.let { template ->
        AlertDialog(
            onDismissRequest = { deleting = null }, title = { Text("Delete ${template.name}?") },
            text = { Text("This cannot be undone.") },
            confirmButton = { TextButton(onClick = { deleting = null; templates = templates - template; SummaryTemplate.custom = templates }) { Text("Delete", color = Brand.dangerText) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text("Custom Templates") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (templates.isEmpty()) Text("Your own templates tell the summary what to look at, for example \u201cNote every price that is mentioned\u201d.")
                for (template in templates) Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { editing = template }, Modifier.weight(1f)) { Text(template.name) }
                    IconButton(onClick = { deleting = template }) { Icon(Icons.Outlined.Delete, "Delete", tint = Brand.dangerText) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { TextButton(onClick = { editing = SummaryTemplate(UUID.randomUUID().toString(), "", "") }) { Text("Add Template") } },
    )
    editing?.let { template ->
        var name by remember(template) { mutableStateOf(template.name) }
        var focus by remember(template) { mutableStateOf(template.focus) }
        AlertDialog(
            onDismissRequest = { editing = null }, title = { Text("Template") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(focus, { focus = it }, label = { Text("What should the summary look at?") }, minLines = 3, modifier = Modifier.fillMaxWidth())
                }
            },
            confirmButton = {
                TextButton(enabled = name.isNotBlank() && focus.isNotBlank(), onClick = {
                    val saved = template.copy(name = name.trim(), focus = focus.trim())
                    templates = if (templates.any { it.id == saved.id }) templates.map { if (it.id == saved.id) saved else it } else templates + saved
                    SummaryTemplate.custom = templates
                    editing = null
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text("Cancel") } },
        )
    }
}

/** iOS: `SyncCard` — Sync über eine Nextcloud mit iPhone und Mac; Anmeldung im Browser (Login Flow v2). */
@Composable
private fun SyncCard() {
    val coroutines = rememberCoroutineScope()
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    val status by NextcloudSync.status.collectAsState()
    var mode by remember { mutableStateOf(SyncMode.chosen) }
    var server by remember { mutableStateOf("") }
    var login by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var loginError by remember { mutableStateOf<String?>(null) }
    Card(
        "Sync",
    ) {
        Picker("Sync With", SyncMode.entries.map { it to it.label }, mode) {
            mode = it
            Prefs.set(SyncMode.KEY, it.raw)
            NextcloudSync.syncSoon(0)
        }
        if (mode == SyncMode.NEXTCLOUD) {
            val account = status.account
            if (account != null) {
                HorizontalDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Account", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    Text(account.label, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Status", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    Text(
                        when {
                            status.syncing -> "Syncing…"
                            status.error != null -> status.error!!
                            status.lastSync != null -> "Synced " + android.text.format.DateUtils.getRelativeTimeSpanString(status.lastSync!!)
                            else -> "Not synced yet"
                        },
                        color = if (status.error != null && !status.syncing) Brand.dangerText else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(2f, fill = false),
                    )
                }
                var wifiOnly by remember { mutableStateOf(Prefs.bool(Keys.RECORDINGS_WIFI_ONLY)) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Upload Recordings on Wi-Fi Only", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    androidx.compose.material3.Switch(wifiOnly, {
                        wifiOnly = it
                        Prefs.set(Keys.RECORDINGS_WIFI_ONLY, it)
                        NextcloudSync.syncSoon(0)
                    }, colors = androidx.compose.material3.SwitchDefaults.colors(checkedTrackColor = Brand.sky))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)) {
                    Pill(if (status.syncing) "Syncing…" else "Sync Now", { coroutines.launch { NextcloudSync.sync() } }, enabled = !status.syncing)
                    Pill("Disconnect", { NextcloudSync.disconnect() })
                }
            } else {
                androidx.compose.material3.OutlinedTextField(
                    value = server, onValueChange = { server = it }, singleLine = true,
                    placeholder = { Text("Server, e.g. cloud.example.com") }, modifier = Modifier.fillMaxWidth(),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                    if (login == null) {
                        Pill("Connect", {
                            val url = NextcloudLogin.normalize(server) ?: return@Pill
                            loginError = null
                            login = coroutines.launch {
                                try {
                                    val pending = NextcloudLogin.start(url)
                                    uriHandler.openUri(pending.loginUrl)
                                    NextcloudSync.connect(NextcloudLogin.finish(pending))
                                } catch (e: kotlinx.coroutines.CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    loginError = e.message
                                } finally {
                                    login = null
                                }
                            }
                        }, enabled = NextcloudLogin.normalize(server) != null)
                    } else {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = Brand.sky)
                        Text("Confirm the login in your browser.", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        Pill("Cancel", { login?.cancel(); login = null })
                    }
                }
                loginError?.let { Text(it, color = Brand.dangerText, style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}

/** iOS: `importCard` — Aufnahmen von außen: vom Plaud-Recorder oder als Audio- oder Videodatei. */
@Composable
private fun PlaudCard(signedIn: Boolean, onSignIn: () -> Unit, onSignOut: () -> Unit) {
    Card("Plaud") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (signedIn) "Signed In" else "Plaud Account", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
            Pill(if (signedIn) "Sign Out" else "Sign In", if (signedIn) onSignOut else onSignIn, destructive = signedIn)
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
    Card("Backup", footer = message) {
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

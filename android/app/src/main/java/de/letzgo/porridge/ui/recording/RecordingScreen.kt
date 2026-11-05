package de.letzgo.porridge.ui.recording

import de.letzgo.porridge.model.RecordingNote
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.key
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.letzgo.porridge.audio.LiveTranscriber
import de.letzgo.porridge.audio.RecordingResult
import de.letzgo.porridge.audio.RecordingSession
import de.letzgo.porridge.data.CalendarAccess
import de.letzgo.porridge.model.clockString
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.SkyFab
import de.letzgo.porridge.ui.components.speakerColor
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** iOS: `RecordMeetingSheet` — die Termine von heute, um eine Aufnahme danach zu benennen, oder „New Meeting“. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordMeetingSheet(onDismiss: () -> Unit, onStart: (title: String?) -> Unit) {
    val context = LocalContext.current
    var appointments by remember { mutableStateOf(CalendarAccess.today(context)) }
    var asked by remember { mutableStateOf(CalendarAccess.hasPermission(context)) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { appointments = CalendarAccess.today(context) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Record Meeting", style = MaterialTheme.typography.titleLarge)
            Surface(onClick = { onStart(null) }, shape = RoundedCornerShape(14.dp), color = Brand.sky.copy(alpha = 0.35f), modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Mic, null, tint = Brand.navy)
                    Text("  New Meeting", color = Brand.navy, style = MaterialTheme.typography.titleMedium)
                }
            }
            if (!asked) {
                TextButton(onClick = { asked = true; permission.launch(Manifest.permission.READ_CALENDAR) }) { Text("Show Today's Appointments") }
            } else if (appointments.isNotEmpty()) {
                Text("Today", style = MaterialTheme.typography.labelLarge, color = Brand.skyText, modifier = Modifier.padding(top = 12.dp))
                HorizontalDivider(thickness = 0.5.dp)
                val time = SimpleDateFormat("HH:mm", Locale.getDefault())
                for (a in appointments) {
                    Row(Modifier.fillMaxWidth().clickable { onStart(a.title) }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Event, null, tint = Brand.navy)
                        Column(Modifier.padding(start = 12.dp)) {
                            Text(a.title)
                            Text(if (a.allDay) "All day" else "${time.format(Date(a.start))} – ${time.format(Date(a.end))}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

/** iOS: `RecordingView` — Meeting-Aufnahme im Vollbild mit Live-Transkript. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RecordingScreen(title: String?, continues: String? = null, onFinish: (RecordingResult, List<String>, String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val coroutines = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDiscard by remember { mutableStateOf(false) }
    var started by remember { mutableStateOf(RecordingSession.isRecording) }
    val names = remember { mutableStateListOf("Speaker 1", "Speaker 2") }
    var finished by remember { mutableStateOf(false) }
    var noteDraft by rememberSaveable { mutableStateOf("") }

    fun finish() {
        if (finished) return
        finished = true
        coroutines.launch {
            // Auch wenn der Bildschirm dabei verschwindet: Die Aufnahme darf nicht halb geschlossen liegen bleiben.
            val (result, text) = withContext(NonCancellable) { RecordingSession.stop() }
            if (noteDraft.isNotBlank() && result != null) RecordingSession.notes += RecordingNote(result.duration, noteDraft.trim())
            if (result != null) onFinish(result, names.toList(), text) else onCancel()
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.RECORD_AUDIO] == true) {
            runCatching { RecordingSession.start(title ?: "Meeting", isMeeting = true, meetingTitle = title, continues = continues) }.onSuccess { started = true }.onFailure { error = it.message }
        } else error = "Please allow microphone access in Settings."
    }
    LaunchedEffect(Unit) {
        if (!started) {
            val perms = buildList {
                add(Manifest.permission.RECORD_AUDIO)
                if (android.os.Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            }
            permission.launch(perms.toTypedArray())
        }
    }
    DisposableEffect(started) {
        val handler: () -> Unit = { finish() }
        if (started) RecordingSession.stopHandler = handler
        onDispose { if (RecordingSession.stopHandler === handler) RecordingSession.stopHandler = null }
    }
    // Nach dem Stoppen wird gespeichert: nichts mehr zu verwerfen.
    BackHandler { if (!finished) confirmDiscard = true }

    val recorder = RecordingSession.recorder
    val live = RecordingSession.live
    val paused = recorder?.isPaused?.collectAsState()?.value == true
    val pausedForCall = recorder?.isPausedForCall?.collectAsState()?.value == true
    // Während eine Notiz getippt wird, braucht die Tastatur den Platz.
    val writing = WindowInsets.isImeVisible
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding().navigationBarsPadding().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { confirmDiscard = true }, enabled = !finished, modifier = Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant)) { Icon(Icons.Filled.Close, "Discard") }
                Spacer(Modifier.weight(1f))
                if (recorder != null) Surface(shape = RoundedCornerShape(50), color = Brand.sky.copy(alpha = 0.14f)) {
                    Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (paused) Icons.Filled.Pause else Icons.Filled.Mic, null, tint = Brand.navy, modifier = Modifier.size(16.dp))
                        Text("  " + if (pausedForCall) "Paused for Call" else if (paused) "Paused" else if (recorder.isSplitStereo) "${recorder.inputName} · 2 channels" else recorder.inputName, style = MaterialTheme.typography.labelLarge, color = Brand.navy)
                    }
                }
            }
            title?.let { Text(it, style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold), textAlign = TextAlign.Center) }
            if (recorder != null) {
                val elapsed by recorder.elapsed.collectAsState()
                val levels by recorder.levels.collectAsState()
                Text(elapsed.clockString, fontSize = if (writing) 28.sp else 56.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Light, color = if (paused) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified)
                if (writing) Unit else if (recorder.isSplitStereo) {
                    for (index in 0..1) Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(12.dp).clip(CircleShape).background(speakerColor(index)))
                        OutlinedTextField(names[index], { names[index] = it }, singleLine = true, modifier = Modifier.padding(horizontal = 12.dp).width(160.dp))
                        LevelBar(levels.getOrElse(index) { 0f }, Modifier.weight(1f))
                    }
                    Text("Each microphone is assigned to one speaker. You can rename them now or later.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                } else LevelBar(levels.maxOrNull() ?: 0f, Modifier.fillMaxWidth())
            }
            if (live != null) LiveCard(live, paused, Modifier.weight(1f)) else Spacer(Modifier.weight(1f))
            if (recorder != null && !finished) {
                val elapsed by recorder.elapsed.collectAsState()
                NoteList(writing)
                NoteField(noteDraft, { noteDraft = it }) {
                    RecordingSession.notes += RecordingNote(elapsed, noteDraft.trim())
                    noteDraft = ""
                }
            }
            // Der Stopp-Knopf nur, solange es etwas zu stoppen gibt: nicht vor dem Start und nicht beim Speichern.
            if (finished) {
                CircularProgressIndicator(Modifier.size(76.dp).padding(16.dp), color = Brand.danger)
            } else if (writing) {
                Unit
            } else if (recorder != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    // Nach einem Anruf geht es von selbst weiter.
                    SkyFab(if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, if (paused) "Resume" else "Pause") { if (!pausedForCall) RecordingSession.setPaused(!paused) }
                    SkyFab(Icons.Filled.Stop, "Stop", Modifier.size(76.dp), container = Brand.danger) { finish() }
                }
            } else {
                Spacer(Modifier.size(76.dp))
            }
        }
    }
    if (confirmDiscard) AlertDialog(
        onDismissRequest = { confirmDiscard = false }, title = { Text("Discard Recording?") },
        confirmButton = { TextButton(onClick = { confirmDiscard = false; RecordingSession.cancel(); onCancel() }) { Text("Discard", color = Brand.dangerText) } },
        dismissButton = { TextButton(onClick = { confirmDiscard = false }) { Text("Cancel") } },
    )
    error?.let { AlertDialog(onDismissRequest = { error = null; onCancel() }, title = { Text("Can't Record") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { error = null; onCancel() }) { Text("OK") } }) }
}

/** Die Notizen bisher als kurze Blasen, die neueste unten. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteList(writing: Boolean) {
    val notes = RecordingSession.notes
    if (notes.isEmpty()) return
    val scroll = rememberScrollState()
    LaunchedEffect(notes.size) { scroll.animateScrollTo(scroll.maxValue) }
    Column(Modifier.fillMaxWidth().heightIn(max = if (writing) 88.dp else 132.dp).verticalScroll(scroll), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (note in notes) key(note.id) {
            var menu by remember { mutableStateOf(false) }
            Box {
                Row(
                    Modifier.padding(start = 48.dp).clip(RoundedCornerShape(14.dp)).background(Brand.sky.copy(alpha = 0.16f))
                        .combinedClickable(onClick = {}, onLongClick = { menu = true }).padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(note.at.clockString, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(note.text, style = MaterialTheme.typography.bodyMedium)
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Delete", color = Brand.dangerText) }, onClick = { menu = false; notes.remove(note) })
                }
            }
        }
    }
}

/** Das Eingabefeld für Notizen. */
@Composable
private fun NoteField(text: String, onText: (String) -> Unit, onAdd: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedTextField(
            text, onText, Modifier.weight(1f), placeholder = { Text("Add a note…") }, singleLine = true, shape = RoundedCornerShape(12.dp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { if (text.isNotBlank()) onAdd() }),
        )
        IconButton(enabled = text.isNotBlank(), onClick = onAdd) { Icon(Icons.AutoMirrored.Filled.Send, "Add Note", tint = if (text.isNotBlank()) Brand.sky else MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun LevelBar(level: Float, modifier: Modifier) {
    LinearProgressIndicator(progress = { level }, modifier = modifier.height(8.dp).clip(RoundedCornerShape(4.dp)), color = Brand.sky, trackColor = MaterialTheme.colorScheme.surfaceVariant)
}

/** iOS: `LiveTranscriptCard`. */
@Composable
private fun LiveCard(live: LiveTranscriber, paused: Boolean, modifier: Modifier) {
    val phase by live.phase.collectAsState()
    val confirmed by live.confirmed.collectAsState()
    val volatile by live.volatile.collectAsState()
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState(), reverseScrolling = true)) {
            when (val p = phase) {
                is LiveTranscriber.Phase.Downloading -> Text("Downloading the speech model (one time) – ${(p.fraction * 100).toInt()} %", color = MaterialTheme.colorScheme.onSurfaceVariant)
                LiveTranscriber.Phase.Preparing, LiveTranscriber.Phase.Idle -> Text("Preparing the live transcript…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                is LiveTranscriber.Phase.Unavailable -> Text(p.message, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LiveTranscriber.Phase.Running -> if (confirmed.isEmpty() && volatile.isEmpty()) Text(if (paused) "Paused" else "Listening…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                else Text(androidx.compose.ui.text.buildAnnotatedString {
                    append(confirmed)
                    if (volatile.isNotEmpty()) {
                        if (confirmed.isNotEmpty()) append(" ")
                        pushStyle(androidx.compose.ui.text.SpanStyle(color = Color.Gray)); append(volatile); pop()
                    }
                }, style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

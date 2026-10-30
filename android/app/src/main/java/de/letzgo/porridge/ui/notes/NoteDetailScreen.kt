package de.letzgo.porridge.ui.notes

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.audio.AudioPlayback
import de.letzgo.porridge.audio.InlineDictation
import de.letzgo.porridge.audio.RecordingSession
import de.letzgo.porridge.logic.ActionItemsLogic
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.clockString
import de.letzgo.porridge.model.durationText
import de.letzgo.porridge.ml.VoiceProfiles
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.LinkOrange
import de.letzgo.porridge.ui.components.MarkdownText
import de.letzgo.porridge.ui.components.SkyFab
import de.letzgo.porridge.ui.components.speakerColor
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private enum class NoteTab(val title: String) { NOTE("Note"), TRANSCRIPT("Transcript"), ARTICLE("Article"), SUMMARY("Summary") }

/**
 * iOS: `NoteDetailView` (Views/Notes/NoteDetailView.swift). Eine neue Notiz ([draft]) liegt nur im Speicher, bis sie
 * Inhalt hat; dann wird sie gespeichert.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NoteDetailScreen(noteID: String, draft: Note?, onClose: () -> Unit) {
    val context = LocalContext.current
    val db = PorridgeDatabase.shared
    val stored by db.notes().observe(noteID).collectAsState(initial = null)
    var local by remember { mutableStateOf(draft) }
    val note = stored ?: local ?: return
    val coroutines = rememberCoroutineScope()
    val stages by ProcessingService.stages.collectAsState()
    val stage = stages[note.id]
    val player = remember { AudioPlayback() }
    val dictation = remember { InlineDictation() }
    val dictationPhase by dictation.phase.collectAsState()
    val editor = remember { NoteEditorController() }
    var liveText by remember { mutableStateOf("") }
    var dictationStart by remember { mutableStateOf(0) }
    var summaryStatus by remember { mutableStateOf<String?>(null) }
    var isSummarizing by remember { mutableStateOf(false) }
    var summaryError by remember { mutableStateOf<String?>(null) }
    var confirmResummarize by remember { mutableStateOf(false) }
    var confirmDeleteAudio by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<Speaker?>(null) }
    var addingTag by remember { mutableStateOf(false) }
    var editingSummary by remember { mutableStateOf(false) }
    var showMerge by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }
    var showMove by remember { mutableStateOf(false) }

    val opensOnSummary = note.isRecording || note.isLink
    val tabs = buildList {
        if (opensOnSummary) add(NoteTab.SUMMARY)
        if (!opensOnSummary || note.text.isNotEmpty()) add(NoteTab.NOTE)
        if (note.isRecording) add(NoteTab.TRANSCRIPT)
        if (note.isLink) add(NoteTab.ARTICLE)
        if (!opensOnSummary) add(NoteTab.SUMMARY)
    }
    var tab by remember { mutableStateOf(if (opensOnSummary) NoteTab.SUMMARY else NoteTab.NOTE) }
    if (tab !in tabs) tab = tabs.first()

    /** Speichert eine geänderte Notiz; eine neue erst, wenn sie Titel oder Text hat. */
    fun update(change: (Note) -> Note) {
        val current = stored ?: local ?: return
        val updated = change(current).copy(updatedAt = System.currentTimeMillis())
        if (stored == null) {
            local = updated
            if (updated.title.isEmpty() && updated.text.isEmpty()) return
        }
        coroutines.launch { db.notes().upsert(updated) }
    }

    LaunchedEffect(note.audioFileName) {
        note.audioFileName?.takeIf { note.hasLocalAudio }?.let { runCatching { player.load(it) } }
    }
    DisposableEffect(Unit) { onDispose { player.stop(); if (dictationPhase == InlineDictation.Phase.RECORDING) dictation.cancel() } }
    // Der Stopp-Knopf in der Benachrichtigung beendet das Diktat.
    val stopRequests by RecordingSession.stopRequests.collectAsState()
    LaunchedEffect(stopRequests) {
        if (stopRequests > 0 && dictation.phase.value == InlineDictation.Phase.RECORDING) finishDictation(dictation, note, dictationStart, ::update) { liveText = "" }
    }
    val liveFlow = RecordingSession.live
    if (liveFlow != null && dictationPhase == InlineDictation.Phase.RECORDING) {
        val confirmed by liveFlow.confirmed.collectAsState()
        val volatile by liveFlow.volatile.collectAsState()
        liveText = listOf(confirmed, volatile).filter { it.isNotEmpty() }.joinToString(" ")
    }
    BackHandler { onClose() }

    suspend fun summarize() {
        if (isSummarizing) return
        tab = NoteTab.SUMMARY
        isSummarizing = true
        summaryStatus = null
        editor.blur()
        delay(150)
        try {
            ProcessingService.summarize(note.id)
        } catch (e: Throwable) {
            summaryError = e.message
        } finally {
            isSummarizing = false
            summaryStatus = null
        }
    }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            // Leiste: zurück, teilen, mehr.
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Brand.navy) }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { share(context, note) }) { Icon(Icons.Filled.Share, "Share", tint = Brand.navy) }
                Box {
                    IconButton(onClick = { showMenu = true }) { Icon(Icons.Filled.MoreVert, "More", tint = Brand.navy) }
                    DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                        fun act(f: () -> Unit) { showMenu = false; f() }
                        if (note.isDeleted) {
                            DropdownMenuItem(text = { Text("Recover") }, onClick = { act { coroutines.launch { NoteStore().restore(note); onClose() } } })
                        } else {
                            DropdownMenuItem(text = { Text(if (note.isPinned) "Unpin" else "Pin") }, onClick = { act { update { it.copy(isPinned = !it.isPinned) } } })
                            DropdownMenuItem(text = { Text(if (note.summary == null) "Summarize" else "Summarize Again") }, enabled = !isSummarizing && canSummarize(note), onClick = {
                                act { if (note.summary == null) coroutines.launch { summarize() } else confirmResummarize = true }
                            })
                            DropdownMenuItem(text = { Text(if (note.summary == null) "Write Summary" else "Edit Summary") }, enabled = !isSummarizing, onClick = { act { tab = NoteTab.SUMMARY; editingSummary = true } })
                            if (note.hasLocalAudio) DropdownMenuItem(text = { Text("Transcribe Again") }, enabled = stage == null, onClick = { act { ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id)) } })
                            if (note.isLink) DropdownMenuItem(text = { Text("Load Page Again") }, enabled = stage == null, onClick = {
                                act { coroutines.launch { db.notes().upsert(note.copy(statusRaw = ProcessingStatus.RECORDED.raw)); ProcessingService.enqueue(ProcessingService.Job.Link(note.id, false)) } }
                            })
                            if (note.segments.isNotEmpty()) {
                                DropdownMenuItem(text = { Text("Copy Transcript") }, onClick = { act { copy(context, note.transcriptText()) } })
                                DropdownMenuItem(text = { Text("Merge with …") }, enabled = stage == null && note.status == ProcessingStatus.READY, onClick = { act { showMerge = true } })
                            }
                            DropdownMenuItem(text = { Text("Move to Folder …") }, onClick = { act { showMove = true } })
                            if (note.hasLocalAudio) DropdownMenuItem(text = { Text("Delete Recording", color = Brand.danger) }, onClick = { act { confirmDeleteAudio = true } })
                            HorizontalDivider()
                            DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { act { coroutines.launch { if (stored != null) NoteStore().trash(note); onClose() } } })
                        }
                    }
                }
            }
            Column(Modifier.padding(horizontal = 16.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Header(note) { title -> update { it.copy(title = title, titleIsCustom = true) } }
                if (note.isDeleted) Text("This note is in Recently Deleted.", color = Brand.danger, style = MaterialTheme.typography.bodySmall)
                else TagRow(note, onAdd = { addingTag = true }) { tag -> update { n -> n.copy(labels = n.labels.filter { !it.equals(tag, true) }) } }
                StatusPanel(note, stage)
                if (note.speakers.isNotEmpty()) SpeakerChips(note.speakers) { renaming = it }
                if (tabs.size > 1) TabSwitcher(tabs, tab) { tab = it }
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        NoteTab.SUMMARY -> SummaryTab(note, isSummarizing, summaryStatus ?: stage, onSummarize = { coroutines.launch { if (note.summary == null) summarize() else confirmResummarize = true } },
                            onEdit = { editingSummary = true }, onInsert = { update { n -> n.copy(text = if (n.text.isEmpty()) n.summary.orEmpty() else n.text + "\n\n" + n.summary) } },
                            onCopy = { copy(context, note.summary.orEmpty()) },
                            onDelete = { coroutines.launch { db.notes().upsert(note.copy(summary = null, summaryModel = null, summarizedAt = null)); db.actionItems().deleteForNote(note.id) } },
                            onToggleTask = { line -> coroutines.launch { toggleSummaryTask(note, line) } })
                        NoteTab.TRANSCRIPT -> TranscriptTab(note, player) { segment, speaker -> update { n -> n.withSegments(n.segments.map { if (it.id == segment.id) it.copy(speakerId = speaker.id) else it }) } }
                        NoteTab.ARTICLE -> ArticleTab(note, stage, context)
                        NoteTab.NOTE -> if (dictationPhase != InlineDictation.Phase.IDLE) {
                            DictationPreview(note.text, dictationStart, liveText, dictationPhase == InlineDictation.Phase.POLISHING)
                        } else {
                            NoteBodyEditor(note.text, { text -> update { it.copy(text = text) } }, editor, Modifier.fillMaxSize(), isEditable = !note.isDeleted, placeholder = "Start typing or dictate …")
                        }
                    }
                }
            }
            if (note.hasLocalAudio && tab != NoteTab.NOTE && !editor.isEditing) {
                PlayerBar(player, Modifier.padding(horizontal = 16.dp, vertical = 8.dp).navigationBarsPadding())
            }
        }
        if (tab == NoteTab.NOTE && stage == null && !note.isDeleted) {
            val recording = dictationPhase == InlineDictation.Phase.RECORDING
            SkyFab(
                if (recording) Icons.Filled.Stop else Icons.Filled.Mic, if (recording) "Stop Dictation" else "Dictate",
                Modifier.align(Alignment.BottomEnd).navigationBarsPadding().imePadding().padding(end = 20.dp, bottom = if (editor.isEditing) 66.dp else 16.dp),
                container = if (recording) Brand.danger else Brand.sky,
            ) {
                when (dictationPhase) {
                    InlineDictation.Phase.IDLE -> {
                        dictationStart = editor.cursorOffset.coerceAtMost(note.text.length)
                        liveText = ""
                        editor.blur()
                        dictation.start(note.title.ifEmpty { "Note" })
                    }
                    InlineDictation.Phase.RECORDING -> coroutines.launch { finishDictation(dictation, note, dictationStart, ::update) { liveText = "" } }
                    InlineDictation.Phase.POLISHING -> Unit
                }
            }
        }
    }

    // Dialoge
    renaming?.let { speaker ->
        TextPrompt("Rename Speaker", speaker.name, "Save", onDismiss = { renaming = null }) { name ->
            renaming = null
            coroutines.launch {
                // Lernt auch die Stimme unter diesem Namen; frühere unbenannte Sprecher werden damit verglichen.
                val voices = VoiceProfiles()
                val speakers = voices.rename(speaker.id, name, note.speakers)
                db.notes().upsert(note.withSpeakers(speakers))
                voices.rematchAllMeetings()
            }
        }
    }
    if (addingTag) TextPrompt("New Tag", "", "Add", onDismiss = { addingTag = false }) { raw ->
        addingTag = false
        val tag = Note.cleanTag(raw)
        if (tag.isNotEmpty() && note.tags.none { it.equals(tag, true) }) update { it.copy(labels = it.labels + tag) }
    }
    if (confirmResummarize) AlertDialog(
        onDismissRequest = { confirmResummarize = false },
        title = { Text("Replace the current summary?") }, text = { Text("Your edits to the summary are lost.") },
        confirmButton = { TextButton(onClick = { confirmResummarize = false; coroutines.launch { summarize() } }) { Text("Summarize Again", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { confirmResummarize = false }) { Text("Cancel") } },
    )
    if (confirmDeleteAudio) AlertDialog(
        onDismissRequest = { confirmDeleteAudio = false },
        title = { Text("Delete recording?") }, text = { Text("The audio file is removed from this device. Transcript, speakers and summary stay.") },
        confirmButton = { TextButton(onClick = { confirmDeleteAudio = false; player.stop(); AudioStore.delete(note.audioFileName); update { it.copy(audioFileName = null) } }) { Text("Delete Recording", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { confirmDeleteAudio = false }) { Text("Cancel") } },
    )
    summaryError?.let { AlertDialog(onDismissRequest = { summaryError = null }, title = { Text("Summary Failed") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { summaryError = null }) { Text("OK") } }) }
    val dictationError by dictation.error.collectAsState()
    dictationError?.let { AlertDialog(onDismissRequest = { dictation.dismissError() }, title = { Text("Dictation") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { dictation.dismissError() }) { Text("OK") } }) }
    if (editingSummary) SummaryEditorSheet(note.summary.orEmpty(), onDismiss = { editingSummary = false }) { text ->
        editingSummary = false
        coroutines.launch {
            val trimmed = text.trim()
            val updated = if (trimmed.isEmpty()) note.copy(summary = null, summaryModel = null, summarizedAt = null) else note.copy(summary = trimmed)
            db.notes().upsert(updated)
            ActionItemStore().sync(updated)
        }
    }
    if (showMerge) MergeNotesSheet(note, onDismiss = { showMerge = false }) { player.stop(); tab = NoteTab.TRANSCRIPT }
    if (showMove) MoveToFolderSheet(note, onDismiss = { showMove = false })
}

private fun canSummarize(note: Note) = !(note.text.isEmpty() && note.title.isEmpty() && note.segments.isEmpty() && note.pageText.isNullOrEmpty())

private fun share(context: Context, note: Note) {
    val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, note.exportText).putExtra(Intent.EXTRA_SUBJECT, note.displayTitle)
    context.startActivity(Intent.createChooser(intent, null))
}

private fun copy(context: Context, text: String) {
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Porridge", text))
}

/** Ein Tipp auf eine Checkbox der Zusammenfassung: die n-te Aufgabenzeile hakt den n-ten Eintrag gleichen Wortlauts ab. */
private suspend fun toggleSummaryTask(note: Note, line: Int) {
    val db = PorridgeDatabase.shared
    val parsed = ActionItemsLogic.parse(note.summary.orEmpty())
    val task = parsed.firstOrNull { it.line == line } ?: return
    val before = parsed.takeWhile { it.line < line }.count { it.key == task.key }
    val store = ActionItemStore()
    var siblings = db.actionItems().forNote(note.id).filter { ActionItemsLogic.key(it) == task.key }
    if (before >= siblings.size) {
        // Noch keine Einträge (alte Zusammenfassung): erst anlegen, dann abhaken.
        store.sync(note)
        siblings = db.actionItems().forNote(note.id).filter { ActionItemsLogic.key(it) == task.key }
    }
    siblings.getOrNull(before)?.let { store.setDone(it, !task.done) }
}

/** Stoppt das Diktat und setzt den endgültigen Text der ganzen Aufnahme an die Cursorstelle. */
private suspend fun finishDictation(dictation: InlineDictation, note: Note, start: Int, update: ((Note) -> Note) -> Unit, done: () -> Unit) {
    val result = dictation.stop() ?: return
    val text = result.text.trim()
    update { n ->
        val at = start.coerceIn(0, n.text.length)
        val before = n.text.substring(0, at)
        val after = n.text.substring(at)
        val lead = if (text.isNotEmpty() && before.isNotEmpty() && !before.last().isWhitespace()) " " else ""
        val newText = before + lead + text + after
        val files = if (result.fileName != null && !(newText.isEmpty() && n.title.isEmpty())) n.audioFileNames + result.fileName else n.audioFileNames
        if (result.fileName != null && newText.isEmpty() && n.title.isEmpty()) AudioStore.delete(result.fileName)
        n.copy(text = newText, audioFileNames = files)
    }
    done()
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Header(note: Note, onTitle: (String) -> Unit) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        var title by remember(note.id) { mutableStateOf(note.title) }
        LaunchedEffect(note.title) { if (note.title != title) title = note.title }
        Box {
            if (title.isEmpty()) Text("Title", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold), color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
            BasicTextField(
                value = title, onValueChange = { title = it; onTitle(it) }, enabled = !note.isDeleted,
                textStyle = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold, color = if (androidx.compose.foundation.isSystemInDarkTheme()) MaterialTheme.colorScheme.onSurface else Brand.navy),
                cursorBrush = SolidColor(Brand.sky), modifier = Modifier.fillMaxWidth(),
            )
        }
        note.domain?.let { domain ->
            Row(Modifier.combinedClickable(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(note.url))) }), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Link, null, tint = LinkOrange, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(domain, color = LinkOrange, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
            }
        }
        val parts = buildList {
            add(SimpleDateFormat("EEEE, d MMMM, HH:mm", Locale.getDefault()).format(Date(note.createdAt)))
            if (note.isRecording && note.duration > 0) add(note.duration.durationText)
            note.inputName?.let { add(it) }
        }
        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TagRow(note: Note, onAdd: () -> Unit, onRemove: (String) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (tag in note.tags) {
            val removable = note.labels.any { it.equals(tag, true) }
            Surface(shape = RoundedCornerShape(50), color = Brand.sky.copy(alpha = 0.18f)) {
                Row(Modifier.padding(start = 12.dp, end = if (removable) 4.dp else 12.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("#$tag", style = MaterialTheme.typography.labelLarge, color = Brand.navy)
                    if (removable) Icon(Icons.Filled.Close, "Remove Tag", tint = Brand.navy, modifier = Modifier.padding(start = 4.dp).size(16.dp).clip(CircleShape).combinedClickable(onClick = { onRemove(tag) }))
                }
            }
        }
        Surface(onClick = onAdd, shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceVariant) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, "Add Tag", tint = Brand.navy, modifier = Modifier.size(16.dp))
                Text(" Tag", style = MaterialTheme.typography.labelLarge, color = Brand.navy)
            }
        }
    }
}

@Composable
private fun StatusPanel(note: Note, stage: String?) {
    when {
        stage != null -> Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
            Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Brand.navy)
                Spacer(Modifier.width(12.dp))
                Text(stage, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
            }
        }
        note.status == ProcessingStatus.READY && note.isRecording && note.errorMessage != null && note.speakerMode == SpeakerMode.NONE -> Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(note.errorMessage, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (note.hasLocalAudio) Button(onClick = { ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id)) }, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky)) { Text("Detect Speakers Again") }
            }
        }
        note.status == ProcessingStatus.FAILED -> Surface(shape = RoundedCornerShape(14.dp), color = Brand.danger.copy(alpha = 0.1f)) {
            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(note.errorMessage ?: "Transcription failed", color = Brand.danger)
                val job = when {
                    note.isLink -> ProcessingService.Job.Link(note.id, false)
                    note.hasLocalAudio -> ProcessingService.Job.Transcript(note.id)
                    AudioStore.exists(note.pendingAudioFileName) -> ProcessingService.Job.NoteAudio(note.id)
                    else -> null
                }
                val coroutines = rememberCoroutineScope()
                if (job != null) Button(onClick = {
                    coroutines.launch {
                        if (note.isLink) PorridgeDatabase.shared.notes().upsert(note.copy(statusRaw = ProcessingStatus.RECORDED.raw))
                        ProcessingService.enqueue(job)
                    }
                }, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky)) { Text("Try Again") }
            }
        }
    }
}

@Composable
private fun SpeakerChips(speakers: List<Speaker>, onRename: (Speaker) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (speaker in speakers) {
            Surface(onClick = { onRename(speaker) }, shape = RoundedCornerShape(50), color = speakerColor(speaker.colorIndex).copy(alpha = 0.18f)) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(speakerColor(speaker.colorIndex)))
                    Text("  ${speaker.name}  ", style = MaterialTheme.typography.labelLarge, color = Brand.navy)
                    Icon(Icons.Filled.Edit, "Rename", tint = Brand.navy, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

@Composable
private fun TabSwitcher(tabs: List<NoteTab>, selected: NoteTab, onSelect: (NoteTab) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        tabs.forEachIndexed { index, tab ->
            SegmentedButton(
                selected = tab == selected, onClick = { onSelect(tab) }, shape = SegmentedButtonDefaults.itemShape(index, tabs.size),
                colors = SegmentedButtonDefaults.colors(activeContainerColor = Brand.sky.copy(alpha = 0.18f), activeContentColor = Brand.navy),
                icon = {},
            ) { Text(tab.title) }
        }
    }
}

@Composable
private fun SummaryTab(
    note: Note, isSummarizing: Boolean, status: String?,
    onSummarize: () -> Unit, onEdit: () -> Unit, onInsert: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit, onToggleTask: (Int) -> Unit,
) {
    val message = when {
        note.isRecording -> "Let AI summarize this meeting – including decisions and action items."
        note.isLink -> "Let AI summarize this page."
        else -> "Let AI summarize this note."
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 96.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when {
            isSummarizing -> Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    CircularProgressIndicator(color = Brand.sky)
                    Text(message, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    status?.let { Text(it, style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold)) }
                }
            }
            note.summary != null -> {
                var menu by remember { mutableStateOf(false) }
                Row(verticalAlignment = Alignment.Top) {
                    MarkdownText(note.summary, Modifier.weight(1f), onToggleTask = if (note.isDeleted) null else onToggleTask)
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreHoriz, "Summary Options", tint = Brand.navy) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("Edit Summary") }, onClick = { menu = false; onEdit() })
                            DropdownMenuItem(text = { Text("Insert into Note") }, onClick = { menu = false; onInsert() })
                            DropdownMenuItem(text = { Text("Copy") }, onClick = { menu = false; onCopy() })
                            DropdownMenuItem(text = { Text("Summarize Again") }, onClick = { menu = false; onSummarize() })
                            HorizontalDivider()
                            DropdownMenuItem(text = { Text("Delete Summary", color = Brand.danger) }, onClick = { menu = false; onDelete() })
                        }
                    }
                }
                note.summaryModel?.let { Text("Created with $it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                Button(onClick = onSummarize, enabled = canSummarize(note), colors = ButtonDefaults.buttonColors(containerColor = Brand.sky), modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.AutoAwesome, null); Text("  Summarize Again")
                }
            }
            else -> Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Icon(Icons.Filled.AutoAwesome, null, tint = Brand.sky, modifier = Modifier.size(40.dp))
                Text(message, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(onClick = onSummarize, enabled = canSummarize(note), colors = ButtonDefaults.buttonColors(containerColor = Brand.sky)) { Icon(Icons.Filled.AutoAwesome, null); Text("  Summarize") }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TranscriptTab(note: Note, player: AudioPlayback, onAssign: (TranscriptSegment, Speaker) -> Unit) {
    val segments = note.segments
    val speakers = note.speakers
    val playing by player.isPlaying.collectAsState()
    val time by player.currentTime.collectAsState()
    val context = LocalContext.current
    if (segments.isEmpty()) {
        Text(if (note.status == ProcessingStatus.READY) "No speech was detected." else "The transcript appears here once processing is done.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
        items(segments, key = { it.id }) { segment ->
            val speaker = speakers.firstOrNull { it.id == segment.speakerId }
            val active = playing && time >= segment.start && time < segment.end
            var menu by remember { mutableStateOf(false) }
            Box {
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(if (active) Brand.sky.copy(alpha = 0.1f) else Color.Transparent)
                        .combinedClickable(onClick = { if (note.hasLocalAudio) { player.seek(segment.start); player.play() } }, onLongClick = { menu = true }).padding(6.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (speaker != null) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(speakerColor(speaker.colorIndex)))
                            Text("  ${speaker.name}", style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold), color = speakerColor(speaker.colorIndex))
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(segment.start.clockString, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(segment.text, style = MaterialTheme.typography.bodyLarge)
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Copy") }, onClick = { menu = false; copy(context, segment.text) })
                    if (speakers.size > 1) {
                        HorizontalDivider()
                        Text("Assign Speaker", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                        for (s in speakers) DropdownMenuItem(text = { Text(s.name) }, onClick = { menu = false; onAssign(segment, s) })
                    }
                }
            }
        }
    }
}

@Composable
private fun ArticleTab(note: Note, stage: String?, context: Context) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
        val text = note.pageText
        when {
            !text.isNullOrEmpty() -> Text(text, style = MaterialTheme.typography.bodyLarge)
            (stage != null || text == null) && note.status != ProcessingStatus.FAILED -> Text("The text of the page appears here once it is loaded.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            note.status != ProcessingStatus.FAILED -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("There is no readable text on this page.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                note.url?.let { url -> Button(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }, colors = ButtonDefaults.buttonColors(containerColor = Brand.sky)) { Text("Open in Browser") } }
            }
        }
    }
}

/** iOS: `dictationPreview` — der Live-Text in der Akzentfarbe mit blinkendem Cursor an der Stelle, wo er erscheint. */
@Composable
private fun DictationPreview(text: String, start: Int, live: String, polishing: Boolean) {
    var on by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) { while (true) { delay(500); on = !on } }
    val at = start.coerceIn(0, text.length)
    val before = text.substring(0, at)
    val after = text.substring(at)
    val trimmed = live.trim()
    val lead = if (trimmed.isNotEmpty() && before.isNotEmpty() && !before.last().isWhitespace()) " " else ""
    val annotated = androidx.compose.ui.text.buildAnnotatedString {
        append(before)
        pushStyle(androidx.compose.ui.text.SpanStyle(color = Brand.sky)); append(lead + trimmed); pop()
        pushStyle(androidx.compose.ui.text.SpanStyle(color = if (on) Brand.sky else Color.Transparent, fontWeight = FontWeight.Bold)); append("|"); pop()
        append(after)
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 5.dp, vertical = 8.dp)) {
        if (polishing) Text("Finishing the transcript …", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
        Text(annotated, style = MaterialTheme.typography.bodyLarge)
    }
}

/** iOS: `PlayerBar` (NoteMediaViews.swift). */
@Composable
private fun PlayerBar(player: AudioPlayback, modifier: Modifier) {
    val playing by player.isPlaying.collectAsState()
    val time by player.currentTime.collectAsState()
    val duration by player.duration.collectAsState()
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceVariant, shadowElevation = 2.dp) {
        Row(Modifier.padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { player.skip(-10.0) }) { Icon(Icons.Filled.Replay10, "Back 10 Seconds", tint = Brand.navy) }
            IconButton(onClick = { player.toggle() }) { Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play", tint = Brand.navy) }
            IconButton(onClick = { player.skip(10.0) }) { Icon(Icons.Filled.Forward10, "Forward 10 Seconds", tint = Brand.navy) }
            Slider(
                value = if (duration > 0) (time / duration).toFloat() else 0f, onValueChange = { player.seek(it * duration) }, modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(thumbColor = Brand.sky, activeTrackColor = Brand.sky),
            )
            Text(" ${time.clockString}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
fun TextPrompt(title: String, initial: String, confirm: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text(title) },
        text = { OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true) },
        confirmButton = { TextButton(enabled = text.isNotBlank(), onClick = { onConfirm(text.trim()) }) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

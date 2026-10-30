package de.letzgo.porridge.ui.notes

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.AppGraph
import de.letzgo.porridge.data.LinkImport
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteScope
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.durationText
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.chat.ChatScreen
import de.letzgo.porridge.ui.components.ChromeBar
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.LinkOrange
import de.letzgo.porridge.ui.components.ListMode
import de.letzgo.porridge.ui.components.ListTabs
import de.letzgo.porridge.ui.components.RowIcon
import de.letzgo.porridge.ui.components.SectionHeader
import de.letzgo.porridge.ui.components.SkyFab
import de.letzgo.porridge.ui.tasks.TasksScreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/** iOS: `NotesView` (Views/Notes/NotesView.swift) — die Liste mit Zeitleiste, Chat, Aufgaben und Suche. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesScreen(
    scope: NoteScope,
    onScope: (NoteScope) -> Unit,
    mode: ListMode,
    onMode: (ListMode) -> Unit,
    onOpen: (String) -> Unit,
    onNewNote: (folderID: String?) -> Unit,
    onRecord: () -> Unit,
    onSettings: () -> Unit,
    onEditTask: (String) -> Unit,
) {
    val db = PorridgeDatabase.shared
    val notes by db.notes().observeAll().collectAsState(initial = emptyList())
    val folders by db.folders().observeAll().collectAsState(initial = emptyList())
    val items by db.actionItems().observeAll().collectAsState(initial = emptyList())
    val stages by ProcessingService.stages.collectAsState()
    val indexVersion by AppGraph.index.version.collectAsState()
    val coroutines = rememberCoroutineScope()
    val context = LocalContext.current
    var search by remember { mutableStateOf("") }
    var tagTokens by remember { mutableStateOf(listOf<String>()) }
    /** Die Ansicht, zu der der Such-Knopf zurückführt. */
    var modeBeforeSearch by remember { mutableStateOf(ListMode.TASKS) }
    var showCreate by remember { mutableStateOf(false) }
    var showAddLink by remember { mutableStateOf(false) }
    var confirmEmptyTrash by remember { mutableStateOf(false) }
    var importError by remember { mutableStateOf<String?>(null) }
    val folderID = (scope as? NoteScope.Folder)?.id

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        coroutines.launch {
            runCatching {
                val name = context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (c.moveToFirst() && i >= 0) c.getString(i) else null
                } ?: "Import"
                val ext = name.substringAfterLast('.', "m4a")
                val fileName = AudioStore.importFile(context, uri, ext)
                val info = AudioStore.audioInfo(fileName)
                val note = Note(
                    title = name.substringBeforeLast('.'), titleIsCustom = true, statusRaw = ProcessingStatus.RECORDED.raw,
                    audioFileName = fileName, inputName = "Import", duration = info?.first ?: 0.0, channelCount = info?.second ?: 1, folderID = folderID,
                )
                db.notes().upsert(note)
                ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
                onMode(ListMode.MEETINGS)
                onOpen(note.id)
            }.onFailure { importError = it.message }
        }
    }

    // Beim Start: Papierkorb leeren, Aufgaben nachtragen, unterbrochene Verarbeitung fortsetzen (iOS: `.task`).
    LaunchedEffect(Unit) {
        NoteStore().purgeExpired()
        ActionItemStore().backfill(db.notes().all())
        // Leer gelassene, von Hand angelegte Aufgaben (Plus getippt, wieder geschlossen) gehen.
        ActionItemStore().dropEmptyManual()
        ProcessingService.resumePending()
    }
    // Der Index folgt den Notizen: nur Geändertes wird neu geschnitten und eingebettet.
    LaunchedEffect(notes) {
        delay(800)
        AppGraph.index.refresh(notes)
    }

    val folderIDs = folders.map { it.id }.toSet()
    val shown = remember(notes, scope, mode, search, tagTokens, indexVersion) {
        var result = when (if (mode == ListMode.SEARCH || mode == ListMode.LINKS) NoteScope.All else scope) {
            NoteScope.All -> notes.filter { !it.isDeleted }
            NoteScope.Unfiled -> notes.filter { !it.isDeleted && (it.folderID == null || it.folderID !in folderIDs) }
            is NoteScope.Folder -> notes.filter { !it.isDeleted && it.folderID == (scope as NoteScope.Folder).id }
            is NoteScope.Tag -> notes.filter { n -> !n.isDeleted && n.tags.any { it.lowercase() == (scope as NoteScope.Tag).name } }
            NoteScope.Trash -> notes.filter { it.isDeleted }
        }
        // Links haben eine eigene Liste; Notizen und Papierkorb lassen sie weg, die Suche findet beides.
        if (mode == ListMode.LINKS) result = result.filter { it.isLink }
        // Meetings und Notizen getrennt; Papierkorb und Suche halten alles.
        else if (mode.showsScope && scope != NoteScope.Trash) result = result.filter { !it.isLink && it.isRecording == (mode == ListMode.MEETINGS) }
        if (mode == ListMode.SEARCH && tagTokens.isNotEmpty()) result = result.filter { n -> tagTokens.all { t -> n.tags.any { it.lowercase() == t } } }
        if (mode == ListMode.SEARCH && search.isNotBlank()) {
            val ids = AppGraph.index.noteIDs(search)
            result = if (ids != null) result.filter { it.id in ids || it.title.contains(search, true) || it.url?.contains(search, true) == true } else result.filter { it.matches(search) }
        }
        if (scope == NoteScope.Trash) result.sortedByDescending { it.deletedAt } else result.sortedByDescending { it.updatedAt }
    }

    val title = when (mode) {
        ListMode.CHAT -> "Chat"
        ListMode.SEARCH -> "Search"
        ListMode.TASKS -> "Tasks"
        ListMode.LINKS -> "Links"
        ListMode.MEETINGS, ListMode.TIMELINE -> when (scope) {
            NoteScope.All -> if (mode == ListMode.MEETINGS) "Meetings" else "Notes"
            NoteScope.Unfiled -> "Notes"
            is NoteScope.Folder -> folders.firstOrNull { it.id == scope.id }?.name ?: "Notes"
            is NoteScope.Tag -> "#" + scope.name
            NoteScope.Trash -> "Recently Deleted"
        }
    }
    val icon: ImageVector = when (mode) {
        ListMode.CHAT -> Icons.Filled.ChatBubble
        ListMode.SEARCH -> Icons.Filled.Search
        ListMode.TASKS -> Icons.Filled.Checklist
        ListMode.LINKS -> Icons.Filled.Link
        ListMode.MEETINGS, ListMode.TIMELINE -> when (scope) {
            NoteScope.All -> if (mode == ListMode.MEETINGS) Icons.Filled.Mic else Icons.Filled.Inbox
            NoteScope.Unfiled -> Icons.AutoMirrored.Filled.Notes
            is NoteScope.Folder -> Icons.Filled.Folder
            is NoteScope.Tag -> Icons.Filled.Tag
            NoteScope.Trash -> Icons.Filled.Delete
        }
    }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(Modifier.fillMaxSize()) {
            ChromeBar(title, icon, tint = when (mode) { ListMode.TASKS -> Brand.task; ListMode.LINKS -> LinkOrange; else -> Brand.sky }) {
                if (mode.showsScope) {
                    FolderMenu(notes, folders, scope, onScope)
                    if (scope != NoteScope.Trash) IconButton(onClick = { importer.launch(arrayOf("audio/*", "video/*")) }) { Icon(Icons.Outlined.Download, "Import Audio", tint = Brand.navy) }
                    if (scope == NoteScope.Trash && shown.isNotEmpty()) IconButton(onClick = { confirmEmptyTrash = true }) { Icon(Icons.Outlined.Delete, "Delete All", tint = Brand.danger) }
                } else if (mode == ListMode.CHAT) {
                    val messages by AppGraph.chat.messages.collectAsState()
                    if (messages.isNotEmpty()) IconButton(onClick = { AppGraph.chat.reset() }) { Icon(Icons.Outlined.EditNote, "New Chat", tint = Brand.navy) }
                }
                // Die Suche ist kein Tab, sondern ein Knopf; nochmals getippt geht es zurück, woher man kam.
                IconButton(onClick = {
                    if (mode == ListMode.SEARCH) { onMode(modeBeforeSearch); search = ""; tagTokens = emptyList() }
                    else { modeBeforeSearch = mode; onMode(ListMode.SEARCH) }
                }) {
                    Icon(if (mode == ListMode.SEARCH) Icons.Filled.Close else Icons.Filled.Search, if (mode == ListMode.SEARCH) "Close Search" else "Search", tint = Brand.navy)
                }
                IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings", tint = Brand.navy) }
            }
            ListTabs(mode) { onMode(it); if (it != ListMode.SEARCH) { search = ""; tagTokens = emptyList() } }
            when (mode) {
                ListMode.MEETINGS, ListMode.TIMELINE -> NoteList(shown, scope, stages, folders.associate { it.id to it.name }, onOpen, Modifier.weight(1f))
                ListMode.LINKS -> NoteList(shown, NoteScope.All, stages, folders.associate { it.id to it.name }, onOpen, Modifier.weight(1f), tint = LinkOrange)
                ListMode.CHAT -> ChatScreen(notes, items, onOpen, Modifier.weight(1f))
                ListMode.TASKS -> TasksScreen(items, notes, onOpen, { onEditTask(it.id) }, Modifier.weight(1f))
                ListMode.SEARCH -> Column(Modifier.weight(1f)) {
                    SearchBar(search, { search = it }, tagTokens, { tagTokens = it }, tagCounts(notes.filter { !it.isDeleted }))
                    if (search.isBlank() && tagTokens.isEmpty()) Spacer(Modifier.height(1.dp))
                    else NoteList(shown, NoteScope.All, stages, folders.associate { it.id to it.name }, onOpen, Modifier.weight(1f), searching = true)
                }
            }
        }
        // Derselbe Plus-Knopf in jeder Ansicht mit Liste (iOS: `createMenu`).
        if (mode == ListMode.TASKS || mode == ListMode.LINKS || (mode.showsScope && scope != NoteScope.Trash)) {
            CreateMenu(
                showCreate, { showCreate = it },
                onTask = {
                    // Die neue Aufgabe zeigt sich dort, wo Aufgaben wohnen.
                    if (mode != ListMode.TASKS) onMode(ListMode.TASKS)
                    coroutines.launch { onEditTask(ActionItemStore().newTask().id) }
                },
                onNote = { if (mode != ListMode.TIMELINE) onMode(ListMode.TIMELINE); onNewNote(folderID) }, onMeeting = onRecord, onLink = { showAddLink = true },
            )
        }
    }

    if (showAddLink) AddLinkDialog(onDismiss = { showAddLink = false }) { address ->
        showAddLink = false
        // Der neue Link zeigt sich dort, wo Links wohnen.
        if (mode != ListMode.LINKS) onMode(ListMode.LINKS)
        coroutines.launch { onOpen(LinkImport.add(address, folderID).id) }
    }
    if (confirmEmptyTrash) AlertDialog(
        onDismissRequest = { confirmEmptyTrash = false },
        title = { Text("Delete all notes in Recently Deleted?") },
        text = { Text("This cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmEmptyTrash = false; coroutines.launch { notes.filter { it.isDeleted }.forEach { NoteStore().deletePermanently(it) } } }) { Text("Delete All", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { confirmEmptyTrash = false }) { Text("Cancel") } },
    )
    importError?.let { AlertDialog(onDismissRequest = { importError = null }, title = { Text("Import Failed") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { importError = null }) { Text("OK") } }) }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun NoteList(
    shown: List<Note>,
    scope: NoteScope,
    stages: Map<String, String>,
    folderNames: Map<String, String>,
    onOpen: (String) -> Unit,
    modifier: Modifier,
    searching: Boolean = false,
    /** Farbe der Abschnittstitel: die der Ansicht (Links orange). */
    tint: Color = Brand.sky,
) {
    val coroutines = rememberCoroutineScope()
    val store = remember { NoteStore() }
    val showsFolder = scope == NoteScope.All || scope is NoteScope.Tag || scope == NoteScope.Trash
    if (shown.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (searching) EmptyState("No Results", "Nothing matches your search.", Icons.Filled.Search)
            else if (scope == NoteScope.Trash) EmptyState("Nothing Deleted", "Deleted notes stay here for ${NoteStore.TRASH_DAYS} days.", Icons.Filled.Delete)
            else EmptyState("No Notes Yet", "Speak a thought – Porridge writes it down for you.", Icons.AutoMirrored.Filled.Notes)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), contentPadding = PaddingValues(bottom = 110.dp)) {
        if (scope == NoteScope.Trash) {
            item { Text("Notes are deleted after ${NoteStore.TRASH_DAYS} days.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) }
            items(shown, key = { it.id }) { note -> SwipeRow(note, stages[note.id], showsFolder, folderNames, onOpen, store, coroutines) }
        } else {
            val pinned = shown.filter { it.isPinned }
            if (pinned.isNotEmpty() && !searching) {
                item(key = "h-pinned") { SectionHeader("Pinned", color = tint) }
                items(pinned, key = { it.id }) { note -> SwipeRow(note, stages[note.id], showsFolder, folderNames, onOpen, store, coroutines) }
            }
            for ((title, group) in groups(if (searching) shown else shown.filter { !it.isPinned })) {
                item(key = "h-$title") { SectionHeader(title, color = tint) }
                items(group, key = { it.id }) { note -> SwipeRow(note, stages[note.id], showsFolder, folderNames, onOpen, store, coroutines) }
            }
        }
    }
}

/** iOS: Zeile mit Wischen — nach rechts anpinnen (oder wiederherstellen), nach links löschen. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun SwipeRow(note: Note, stage: String?, showsFolder: Boolean, folderNames: Map<String, String>, onOpen: (String) -> Unit, store: NoteStore, coroutines: kotlinx.coroutines.CoroutineScope) {
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> {
                coroutines.launch { if (note.isDeleted) store.restore(note) else PorridgeDatabase.shared.notes().upsert(note.copy(isPinned = !note.isPinned)) }
                false
            }
            SwipeToDismissBoxValue.EndToStart -> {
                coroutines.launch { if (note.isDeleted) store.deletePermanently(note) else store.trash(note) }
                true
            }
            SwipeToDismissBoxValue.Settled -> false
        }
    })
    var menu by remember { mutableStateOf(false) }
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val toStart = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier.fillMaxSize().background(if (toStart) Brand.danger else if (note.isDeleted) Brand.sky else Color(0xFFF2994A)).padding(horizontal = 24.dp),
                contentAlignment = if (toStart) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                Icon(if (toStart) Icons.Outlined.Delete else if (note.isDeleted) Icons.Outlined.Undo else Icons.Outlined.PushPin, null, tint = Color.White)
            }
        },
    ) {
        Box {
            NoteRow(note, stage, if (showsFolder) note.folderID?.let { folderNames[it] } else null, Modifier.combinedClickable(onClick = { onOpen(note.id) }, onLongClick = { menu = true }))
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (note.isDeleted) {
                    DropdownMenuItem(text = { Text("Recover") }, onClick = { menu = false; coroutines.launch { store.restore(note) } })
                    DropdownMenuItem(text = { Text("Delete Now", color = Brand.danger) }, onClick = { menu = false; coroutines.launch { store.deletePermanently(note) } })
                } else {
                    DropdownMenuItem(text = { Text(if (note.isPinned) "Unpin" else "Pin") }, onClick = { menu = false; coroutines.launch { PorridgeDatabase.shared.notes().upsert(note.copy(isPinned = !note.isPinned)) } })
                    DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { menu = false; coroutines.launch { store.trash(note) } })
                }
            }
        }
    }
}

/** iOS: `NoteRow` — Notizen in Sky, Meetings in Navy, Links in Orange. */
@Composable
private fun NoteRow(note: Note, stage: String?, folderName: String?, modifier: Modifier) {
    val (icon, tint) = when {
        note.isLink -> Icons.Filled.Link to LinkOrange
        note.isRecording -> Icons.Outlined.GraphicEq to Brand.navy
        else -> Icons.AutoMirrored.Filled.Notes to Brand.sky
    }
    Surface(color = MaterialTheme.colorScheme.background, modifier = modifier) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    RowIcon(icon, tint)
                    if (note.isPinned) Icon(Icons.Filled.PushPin, "Pinned", tint = Color(0xFFF2994A), modifier = Modifier.size(12.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(note.displayTitle, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (note.preview.isNotEmpty()) Text(note.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val footer = buildList {
                        val deletedAt = note.deletedAt
                        if (deletedAt != null) {
                            val left = NoteStore.TRASH_DAYS - TimeUnit.MILLISECONDS.toDays(System.currentTimeMillis() - deletedAt).toInt()
                            add(if (left <= 1) "Deleted tomorrow" else "$left days left")
                        } else add(SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(note.updatedAt)))
                        folderName?.let { add(it) }
                        note.domain?.let { add(it) }
                        if (note.isRecording && note.duration > 0) add(note.duration.durationText)
                        stage?.let { add(it) } ?: if (note.status == ProcessingStatus.FAILED) add("Failed") else Unit
                    }
                    Text(footer.joinToString("  ·  "), style = MaterialTheme.typography.labelSmall, color = if (note.isDeleted) Brand.danger.copy(alpha = 0.8f) else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, modifier = Modifier.padding(top = 2.dp))
                }
            }
            HorizontalDivider(Modifier.padding(start = 58.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

/** iOS: Gruppen Today, Yesterday, Previous 7 Days, Previous 30 Days, Monate, Jahre. */
private fun groups(list: List<Note>): List<Pair<String, List<Note>>> {
    val result = mutableListOf<Pair<String, MutableList<Note>>>()
    val today = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
    val year = today.get(Calendar.YEAR)
    for (note in list) {
        val day = Calendar.getInstance().apply { timeInMillis = note.updatedAt; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        val days = TimeUnit.MILLISECONDS.toDays(today.timeInMillis - day.timeInMillis).toInt()
        val title = when {
            days <= 0 -> "Today"
            days == 1 -> "Yesterday"
            days <= 7 -> "Previous 7 Days"
            days <= 30 -> "Previous 30 Days"
            day.get(Calendar.YEAR) == year -> SimpleDateFormat("MMMM", Locale.getDefault()).format(Date(note.updatedAt))
            else -> day.get(Calendar.YEAR).toString()
        }
        if (result.lastOrNull()?.first == title) result.last().second += note else result += title to mutableListOf(note)
    }
    return result
}

/** iOS: `createMenu` — ein Plus-Knopf unten rechts, der sich in Notiz, Meeting und Link aufklappt. */
@Composable
private fun CreateMenu(open: Boolean, onOpen: (Boolean) -> Unit, onTask: () -> Unit, onNote: () -> Unit, onMeeting: () -> Unit, onLink: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        if (open) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.08f)).combinedClickableNoRipple { onOpen(false) })
        Column(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(end = 22.dp, bottom = 16.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            AnimatedVisibility(open) {
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    CreateOption("Task", Icons.Filled.Checklist) { onOpen(false); onTask() }
                    CreateOption("Link", Icons.Filled.Link) { onOpen(false); onLink() }
                    CreateOption("Meeting", Icons.Filled.Mic) { onOpen(false); onMeeting() }
                    CreateOption("Note", Icons.Outlined.EditNote) { onOpen(false); onNote() }
                }
            }
            SkyFab(Icons.Filled.Add, if (open) "Close" else "Create", Modifier.rotate(if (open) 45f else 0f)) { onOpen(!open) }
        }
    }
}

@Composable
private fun CreateOption(title: String, icon: ImageVector, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, shadowElevation = 6.dp, color = MaterialTheme.colorScheme.surface) {
        Row(Modifier.height(48.dp).padding(start = 16.dp, end = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = Brand.sky, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
            Text(title, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold))
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableNoRipple(onClick: () -> Unit) = this.then(
    Modifier.combinedClickable(interactionSource = null, indication = null, onClick = onClick),
)

/** iOS: Dialog „Add Link“. */
@Composable
private fun AddLinkDialog(onDismiss: () -> Unit, onAdd: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    val address = LinkImport.webAddress(text)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Link") },
        text = {
            Column {
                Text("The page is saved as a note and summarized.", style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = text, onValueChange = { text = it }, placeholder = { Text("https://") }, singleLine = true)
            }
        },
        confirmButton = { TextButton(enabled = address != null, onClick = { address?.let(onAdd) }) { Text("Add") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

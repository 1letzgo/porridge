package de.letzgo.porridge.ui.notes

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Unarchive
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
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
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
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.logic.HomeListLogic
import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.durationText
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.chat.ChatPanel
import de.letzgo.porridge.ui.components.ChromeBar
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.LinkOrange
import de.letzgo.porridge.ui.components.ListPage
import de.letzgo.porridge.ui.components.RowIcon
import de.letzgo.porridge.ui.components.SectionHeader
import de.letzgo.porridge.ui.components.SkyFab
import de.letzgo.porridge.ui.projects.ProjectChooser
import de.letzgo.porridge.ui.projects.ProjectDetail
import de.letzgo.porridge.ui.projects.ProjectRow
import de.letzgo.porridge.ui.projects.sortedByName
import de.letzgo.porridge.ui.tasks.TaskListRow
import de.letzgo.porridge.ui.tasks.taskSections
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Was bleibt, während eine Notiz offen ist: die Liste selbst verlässt dann die Komposition, ihre Seite, Suche und
 * Scroll-Position hält die Wurzel.
 */
@Stable
class ListState {
    var page by mutableStateOf<ListPage>(ListPage.Home)
    var search by mutableStateOf("")
    var tagTokens by mutableStateOf(listOf<String>())
    /** Die in der Suche gewählte Art (null = alle). */
    var searchKind by mutableStateOf<ProjectsLogic.Kind?>(null)
    var showDone by mutableStateOf(false)
    private val scrollStates = HashMap<ListPage, LazyListState>()

    fun scroll(page: ListPage): LazyListState = scrollStates.getOrPut(page) { LazyListState() }

    fun clearSearch() { search = ""; tagTokens = emptyList(); searchKind = null }
}

/** iOS: `NotesView` (Views/Notes/NotesView.swift) — die eine lange Liste, ihre Unterseiten und darüber der Chat. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesScreen(
    list: ListState,
    onOpen: (String) -> Unit,
    /** Neue Notiz, auf Wunsch gleich in einem Projekt. */
    onNewNote: (projectID: String?) -> Unit,
    onRecord: () -> Unit,
    onSettings: () -> Unit,
    onEditTask: (String) -> Unit,
) {
    val db = PorridgeDatabase.shared
    // Bis die Datenbank geantwortet hat, ist nichts da: eine leere Liste setzte die Scroll-Position zurück.
    val loadedNotes by db.notes().observeAll().collectAsState(initial = null)
    val loadedItems by db.actionItems().observeAll().collectAsState(initial = null)
    val loadedFolders by db.folders().observeAll().collectAsState(initial = null)
    val notes = loadedNotes.orEmpty()
    val items = loadedItems.orEmpty()
    val folders = loadedFolders.orEmpty()
    val loaded = loadedNotes != null && loadedItems != null && loadedFolders != null
    val page = list.page
    val openProject = (page as? ListPage.Project)?.let { p -> folders.firstOrNull { it.id == p.id } }
    val stages by ProcessingService.stages.collectAsState()
    val indexVersion by AppGraph.index.version.collectAsState()
    val coroutines = rememberCoroutineScope()
    val context = LocalContext.current
    /** Der Chat liegt über der jeweiligen Ansicht (iOS: `ChatSheet`). */
    var showChat by remember { mutableStateOf(false) }
    /** Die Suche ebenso, als Karte neben dem Chat. */
    var showSearch by remember { mutableStateOf(false) }
    var creatingProject by remember { mutableStateOf(false) }
    /** Wohin Neues kommt: ins offene Projekt. */
    val projectForNew = (page as? ListPage.Project)?.id
    var showCreate by remember { mutableStateOf(false) }
    var showAddLink by remember { mutableStateOf(false) }
    var confirmEmptyTrash by remember { mutableStateOf(false) }

    // Beim Start: Papierkorb leeren, Aufgaben nachtragen, unterbrochene Verarbeitung fortsetzen (iOS: `.task`).
    LaunchedEffect(Unit) {
        NoteStore().purgeExpired()
        // Ordner werden Projekte (einmalig; danach hat keine Notiz mehr einen Ordner).
        Projects.migrateFolders()
        ActionItemStore().backfill(db.notes().all())
        // Leer gelassene, von Hand angelegte Aufgaben (Plus getippt, wieder geschlossen) gehen.
        ActionItemStore().dropEmptyManual()
        ProcessingService.resumePending()
    }
    // Der Index folgt den Notizen: nur Geändertes wird neu geschnitten und eingebettet.
    LaunchedEffect(loadedNotes) {
        val current = loadedNotes ?: return@LaunchedEffect
        delay(800)
        AppGraph.index.refresh(current)
    }
    // Das offene Projekt ist weg (anderswo gelöscht): zurück zum Anfang. Gefragt wird die Datenbank, weil ein gerade
    // angelegtes Projekt in der Beobachtung noch fehlen kann.
    LaunchedEffect(page, loadedFolders) {
        if (page is ListPage.Project && db.folders().count(page.id) == 0) list.page = ListPage.Home
    }

    fun goBack() {
        // Ein archiviertes Projekt wurde aus dem Archiv geöffnet.
        list.page = if (openProject?.archivedAt != null) ListPage.Archive else ListPage.Home
    }
    fun closeSearch() { showSearch = false; list.clearSearch() }
    // Die Zurück-Geste (auch vom Rand) schließt erst die offene Karte, dann die Unterseite.
    BackHandler(enabled = page != ListPage.Home) { goBack() }
    BackHandler(enabled = showChat) { showChat = false }
    BackHandler(enabled = showSearch) { closeSearch() }

    val trash = remember(notes) { notes.filter { it.isDeleted }.sortedByDescending { it.deletedAt } }

    val title = when (page) {
        ListPage.Home -> "Porridge"
        is ListPage.Project -> openProject?.name?.ifEmpty { "Untitled Project" }.orEmpty()
        ListPage.Archive -> "Archive"
        ListPage.Trash -> "Recently Deleted"
    }
    val icon: ImageVector = when (page) {
        ListPage.Home -> Icons.Filled.Inbox
        is ListPage.Project -> Icons.Filled.Folder
        ListPage.Archive -> Icons.Filled.Archive
        ListPage.Trash -> Icons.Filled.Delete
    }
    val tint = if (page is ListPage.Project) Brand.project else Brand.sky

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(Modifier.fillMaxSize()) {
            ChromeBar(title, icon, tint = tint, onBack = if (page == ListPage.Home) null else ({ goBack() })) {
                if (page == ListPage.Trash && trash.isNotEmpty()) IconButton(onClick = { confirmEmptyTrash = true }) { Icon(Icons.Outlined.Delete, "Delete All", tint = Brand.danger) }
                if (page == ListPage.Home) IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings", tint = Brand.navy) }
            }
            val listModifier = Modifier.weight(1f)
            val scroll = list.scroll(page)
            when {
                !loaded -> Spacer(listModifier)
                page == ListPage.Home -> HomeList(list, notes, items, folders, stages, onOpen, { onEditTask(it.id) }, scroll, listModifier)
                page is ListPage.Project ->
                    if (openProject == null) Spacer(listModifier)
                    else ProjectDetail(openProject, notes, items, stages, onOpen, { onEditTask(it.id) }, scroll, listModifier)
                page == ListPage.Archive -> ArchiveList(notes, items, folders, stages, onOpen, { onEditTask(it.id) }, { list.page = ListPage.Project(it) }, scroll, listModifier)
                else -> TrashList(trash, stages, onOpen, scroll, listModifier)
            }
        }
        // Derselbe Plus-Knopf auf jeder Seite, unten links Chat und Suche (iOS: `createMenu`). In einem offenen Projekt
        // kommt alles Neue ins Projekt; die Liste bleibt, wo sie ist, das Neue öffnet sich darüber.
        CreateMenu(
            showCreate, { showCreate = it },
            showsPlus = page != ListPage.Archive && page != ListPage.Trash,
            onProject = if (page == ListPage.Home) ({ creatingProject = true }) else null,
            onTask = {
                coroutines.launch {
                    val item = ActionItemStore().newTask()
                    projectForNew?.let { Projects.toggle(item, it) }
                    onEditTask(item.id)
                }
            },
            onNote = { onNewNote(projectForNew) },
            onMeeting = onRecord, onLink = { showAddLink = true },
            showChat = showChat, onChat = { showChat = it },
            chat = { ChatPanel(notes, items, onOpen = { id -> showChat = false; onOpen(id) }, onClose = { showChat = false }) },
            showSearch = showSearch, onSearch = { if (it) showSearch = true else closeSearch() },
            // Ein Treffer schließt die Karte; die Anfrage bleibt für den Weg zurück zu den Treffern.
            search = {
                SearchPanel(
                    list, notes, items, stages, indexVersion,
                    onOpen = { id -> showSearch = false; onOpen(id) },
                    onEditTask = { item -> showSearch = false; onEditTask(item.id) },
                )
            },
        )
    }

    if (showAddLink) AddLinkDialog(onDismiss = { showAddLink = false }) { address ->
        showAddLink = false
        val pid = projectForNew
        coroutines.launch {
            val note = LinkImport.add(address)
            pid?.let { Projects.toggle(note, it) }
            onOpen(note.id)
        }
    }
    if (creatingProject) TextPrompt("New Project", "", "Create", onDismiss = { creatingProject = false }) { name ->
        creatingProject = false
        coroutines.launch { list.page = ListPage.Project(Projects.create(name).id) }
    }
    if (confirmEmptyTrash) AlertDialog(
        onDismissRequest = { confirmEmptyTrash = false },
        title = { Text("Delete all notes in Recently Deleted?") },
        text = { Text("This cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmEmptyTrash = false; coroutines.launch { notes.filter { it.isDeleted }.forEach { NoteStore().deletePermanently(it) } } }) { Text("Delete All", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { confirmEmptyTrash = false }) { Text("Cancel") } },
    )
}

/** iOS: Startseite von `NotesView` — Projekte, Angeheftetes, Aufgaben, dann Meetings, Notizen und Links nach Datum; am Ende Archiv und Papierkorb. */
@Composable
private fun HomeList(
    list: ListState, notes: List<Note>, items: List<ActionItem>, folders: List<NoteFolder>, stages: Map<String, String>,
    onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val projects = remember(folders) { HomeListLogic.activeProjects(folders).sortedByName() }
    val tasks = remember(items, notes, folders) { HomeListLogic.homeTasks(items, notes, folders) }
    val home = remember(notes, folders) { HomeListLogic.homeNotes(notes, folders) }
    val (pinned, rest) = remember(home) { home.partition { it.isPinned } }
    val archiveCount = remember(folders, notes, items) { HomeListLogic.archiveCount(folders, notes, items) }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        if (projects.isNotEmpty()) {
            item(key = "h-projects") { SectionHeader("Projects", color = Brand.project) }
            projectRows(projects, notes, items) { list.page = ListPage.Project(it) }
        }
        if (pinned.isNotEmpty()) {
            item(key = "h-pinned") { SectionHeader("Pinned") }
            noteRows(pinned, stages, onOpen)
        }
        taskSections(tasks, list.showDone, { list.showDone = it }, onOpen, onEditTask)
        dateGroups(rest, stages, onOpen)
        if (projects.isEmpty() && tasks.isEmpty() && home.isEmpty()) {
            item(key = "empty") { EmptyState("No Notes Yet", "Speak a thought – Porridge writes it down for you.", Icons.AutoMirrored.Filled.Notes) }
        }
        item(key = "row-archive") { Column(Modifier.padding(top = 16.dp)) { PageRow("Archive", Icons.Filled.Archive, archiveCount) { list.page = ListPage.Archive } } }
        item(key = "row-trash") { PageRow("Recently Deleted", Icons.Filled.Delete, notes.count { it.isDeleted }) { list.page = ListPage.Trash } }
    }
}

/** Das Archiv: Projekte (sie lassen sich öffnen), dann Aufgaben, dann Notizen nach Datum. */
@Composable
private fun ArchiveList(
    notes: List<Note>, items: List<ActionItem>, folders: List<NoteFolder>, stages: Map<String, String>,
    onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit, onProject: (String) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val projects = remember(folders) { HomeListLogic.archivedProjects(folders).sortedByName() }
    val tasks = remember(items, notes) { HomeListLogic.archivedTasks(items, notes) }
    val archived = remember(notes) { HomeListLogic.archivedNotes(notes) }
    if (projects.isEmpty() && tasks.isEmpty() && archived.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("Nothing Archived", "Archive projects, tasks and notes you are done with. They stay in chat and search.", Icons.Filled.Archive)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        if (projects.isNotEmpty()) {
            item(key = "h-projects") { SectionHeader("Projects", color = Brand.project) }
            projectRows(projects, notes, items, onProject)
        }
        taskRows("Tasks", tasks, onOpen, onEditTask)
        dateGroups(archived, stages, onOpen)
    }
}

@Composable
private fun TrashList(trash: List<Note>, stages: Map<String, String>, onOpen: (String) -> Unit, state: LazyListState, modifier: Modifier) {
    if (trash.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("Nothing Deleted", "Deleted notes stay here for ${NoteStore.TRASH_DAYS} days.", Icons.Filled.Delete)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        item(key = "hint") { Text("Notes are deleted after ${NoteStore.TRASH_DAYS} days.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) }
        noteRows(trash, stages, onOpen)
    }
}

/** iOS: `SearchPane` als Karte — Suchfeld, Arten und Tags, darunter die Treffer: auch Archiviertes, Aufgaben zuerst. */
@Composable
private fun SearchPanel(
    list: ListState, notes: List<Note>, items: List<ActionItem>, stages: Map<String, String>, indexVersion: Any?,
    onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit,
) {
    val tags = remember(notes) { tagCounts(notes.filter { !it.isDeleted }) }
    Column(Modifier.fillMaxSize()) {
        SearchBar(list.search, { list.search = it }, list.tagTokens, { list.tagTokens = it }, tags, list.searchKind, { list.searchKind = it })
        if (list.search.isNotBlank() || list.tagTokens.isNotEmpty() || list.searchKind != null) {
            SearchResults(list, notes, items, stages, indexVersion, onOpen, onEditTask, Modifier.weight(1f))
        }
    }
}

@Composable
private fun SearchResults(
    list: ListState, notes: List<Note>, items: List<ActionItem>, stages: Map<String, String>, indexVersion: Any?,
    onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit, modifier: Modifier,
) {
    val query = list.search
    val tokens = list.tagTokens
    val kind = list.searchKind
    val foundNotes = remember(notes, query, tokens, kind, indexVersion) {
        HomeListLogic.searchNotes(notes, query, tokens, kind, if (query.isBlank()) null else AppGraph.index.noteIDs(query))
    }
    val foundTasks = remember(items, notes, query, tokens, kind) { HomeListLogic.searchTasks(items, notes, query, tokens, kind) }
    if (foundNotes.isEmpty() && foundTasks.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { EmptyState("No Results", "Nothing matches your search.", Icons.Filled.Search) }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = rememberLazyListState(), contentPadding = PaddingValues(bottom = 16.dp)) {
        taskRows("Tasks", foundTasks, onOpen, onEditTask)
        dateGroups(foundNotes, stages, onOpen)
    }
}

private fun LazyListScope.projectRows(projects: List<NoteFolder>, notes: List<Note>, items: List<ActionItem>, onProject: (String) -> Unit) {
    items(projects, key = { "p-" + it.id }) { project -> ProjectRow(project, notes, items, onProject) }
}

private fun LazyListScope.noteRows(notes: List<Note>, stages: Map<String, String>, onOpen: (String) -> Unit) {
    items(notes, key = { "n-" + it.id }) { note -> NoteSwipeRow(note, stages[note.id], onOpen) }
}

private fun LazyListScope.taskRows(title: String, tasks: List<Pair<ActionItem, Note?>>, onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit) {
    if (tasks.isEmpty()) return
    item(key = "h-$title") { SectionHeader(title, tasks.size, color = Brand.task) }
    items(tasks, key = { "t-" + it.first.id }) { (item, note) -> TaskListRow(item, note, onOpen, onEditTask) }
}

private fun LazyListScope.dateGroups(notes: List<Note>, stages: Map<String, String>, onOpen: (String) -> Unit) {
    for ((title, group) in groups(notes)) {
        item(key = "h-$title") { SectionHeader(title) }
        noteRows(group, stages, onOpen)
    }
}

/** Eine Zeile am Ende der Liste, die zu einer Unterseite führt. */
@Composable
private fun PageRow(title: String, icon: ImageVector, count: Int, onClick: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.clickable(onClick = onClick)) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                RowIcon(icon, Brand.navy)
                Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Text(count.toString(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            HorizontalDivider(Modifier.padding(start = 58.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

/**
 * iOS: Zeile mit Wischen — nach rechts archivieren (im Archiv zurückholen, im Papierkorb wiederherstellen), nach links
 * löschen. Anpinnen geht über das lange Drücken. [projectID]: das Projekt der offenen Seite, aus dem sie sich nehmen lässt.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun NoteSwipeRow(note: Note, stage: String?, onOpen: (String) -> Unit, projectID: String? = null) {
    val coroutines = rememberCoroutineScope()
    val store = remember { NoteStore() }
    // Der Zustand des Wischens behält seinen ersten Callback; so sieht er immer den aktuellen Stand.
    val current by rememberUpdatedState(note)
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        val latest = current
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> {
                coroutines.launch {
                    when {
                        latest.isDeleted -> store.restore(latest)
                        latest.archivedAt != null -> store.unarchive(latest)
                        else -> store.archive(latest)
                    }
                }
                // Die Zeile federt zurück: in der Suche bleibt sie stehen.
                false
            }
            SwipeToDismissBoxValue.EndToStart -> {
                coroutines.launch { if (latest.isDeleted) store.deletePermanently(latest) else store.trash(latest) }
                true
            }
            SwipeToDismissBoxValue.Settled -> false
        }
    })
    var menu by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    if (choosing) ProjectChooser(note.projectIDs, onToggle = { id -> coroutines.launch { Projects.toggle(note, id) } }, onDismiss = { choosing = false })
    val archived = note.archivedAt != null
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val toStart = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier.fillMaxSize().background(if (toStart) Brand.danger else if (note.isDeleted || archived) Brand.sky else Brand.navy).padding(horizontal = 24.dp),
                contentAlignment = if (toStart) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                Icon(if (toStart) Icons.Outlined.Delete else if (note.isDeleted) Icons.Outlined.Undo else if (archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive, null, tint = Color.White)
            }
        },
    ) {
        Box {
            NoteRow(note, stage, Modifier.combinedClickable(onClick = { onOpen(note.id) }, onLongClick = { menu = true }))
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (note.isDeleted) {
                    DropdownMenuItem(text = { Text("Recover") }, onClick = { menu = false; coroutines.launch { store.restore(note) } })
                    DropdownMenuItem(text = { Text("Delete Now", color = Brand.danger) }, onClick = { menu = false; coroutines.launch { store.deletePermanently(note) } })
                } else {
                    if (!archived) DropdownMenuItem(text = { Text(if (note.isPinned) "Unpin" else "Pin") }, onClick = { menu = false; coroutines.launch { PorridgeDatabase.shared.notes().upsert(note.copy(isPinned = !note.isPinned)) } })
                    DropdownMenuItem(text = { Text(if (archived) "Unarchive" else "Archive") }, onClick = { menu = false; coroutines.launch { if (archived) store.unarchive(note) else store.archive(note) } })
                    DropdownMenuItem(text = { Text("Projects…") }, onClick = { menu = false; choosing = true })
                    if (projectID != null) DropdownMenuItem(text = { Text("Remove from Project") }, onClick = { menu = false; coroutines.launch { Projects.toggle(note, projectID) } })
                    DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { menu = false; coroutines.launch { store.trash(note) } })
                }
            }
        }
    }
}

/** iOS: `NoteRow` — Notizen in Sky, Meetings in Navy, Links in Orange. */
@Composable
internal fun NoteRow(note: Note, stage: String?, modifier: Modifier) {
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
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CreateMenu(
    open: Boolean, onOpen: (Boolean) -> Unit, showsPlus: Boolean, onProject: (() -> Unit)?,
    onTask: () -> Unit, onNote: () -> Unit, onMeeting: () -> Unit, onLink: () -> Unit,
    showChat: Boolean, onChat: (Boolean) -> Unit, chat: @Composable () -> Unit,
    showSearch: Boolean, onSearch: (Boolean) -> Unit, search: @Composable () -> Unit,
) {
    val cardOpen = showChat || showSearch
    // Beim Zuklappen bleibt die Karte stehen, die zuletzt offen war.
    var searchLast by remember { mutableStateOf(false) }
    if (cardOpen) searchLast = showSearch
    Box(Modifier.fillMaxSize()) {
        if (open || cardOpen) Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = if (cardOpen) 0.18f else 0.08f)).combinedClickableNoRipple {
                onOpen(false)
                if (showChat) onChat(false)
                if (showSearch) onSearch(false)
            },
        )
        // Chat und Suche klappen wie das Plus-Menü aus ihrem Knopf auf: eine Karte über der Ansicht (iOS: `ChatPanel`).
        Column(Modifier.align(Alignment.BottomStart).fillMaxSize().imePadding().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp)) {
            AnimatedVisibility(cardOpen, Modifier.weight(1f)) {
                Surface(shape = RoundedCornerShape(22.dp), shadowElevation = 10.dp, color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize().padding(bottom = 14.dp)) {
                    if (searchLast) search() else chat()
                }
            }
            if (!cardOpen) Spacer(Modifier.weight(1f))
            // Mit Tastatur reicht die Karte bis an sie heran; der Knopf tritt so lange zur Seite. Bei offener Karte bleibt nur ihr Knopf.
            if (!(cardOpen && WindowInsets.isImeVisible)) Row(Modifier.padding(start = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (!showSearch) SkyFab(if (showChat) Icons.Filled.Close else Icons.Filled.ChatBubble, if (showChat) "Close Chat" else "Chat", container = Brand.chat) { onOpen(false); onChat(!showChat) }
                if (!showChat) SkyFab(if (showSearch) Icons.Filled.Close else Icons.Filled.Search, if (showSearch) "Close Search" else "Search", container = Brand.navy) { onOpen(false); onSearch(!showSearch) }
            }
        }
        if (showsPlus && !cardOpen) Column(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(end = 22.dp, bottom = 16.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            AnimatedVisibility(open) {
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (onProject != null) CreateOption("Project", Icons.Filled.Folder, Brand.project) { onOpen(false); onProject() }
                    CreateOption("Task", Icons.Filled.Checklist, Brand.task) { onOpen(false); onTask() }
                    CreateOption("Link", Icons.Filled.Link, LinkOrange) { onOpen(false); onLink() }
                    CreateOption("Meeting", Icons.Filled.Mic, Brand.navy) { onOpen(false); onMeeting() }
                    CreateOption("Note", Icons.Outlined.EditNote, Brand.sky) { onOpen(false); onNote() }
                }
            }
            SkyFab(Icons.Filled.Add, if (open) "Close" else "Create", Modifier.rotate(if (open) 45f else 0f)) { onOpen(!open) }
        }
    }
}

@Composable
private fun CreateOption(title: String, icon: ImageVector, tint: Color, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, shadowElevation = 6.dp, color = MaterialTheme.colorScheme.surface) {
        Row(Modifier.height(48.dp).padding(start = 16.dp, end = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
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

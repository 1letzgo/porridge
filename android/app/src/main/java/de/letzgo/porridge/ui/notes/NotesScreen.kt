package de.letzgo.porridge.ui.notes

import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import de.letzgo.porridge.logic.InboxLogic
import de.letzgo.porridge.ui.components.pageTransition
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.ExpandLess
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.GraphicEq
import de.letzgo.porridge.plaud.PlaudAccount
import de.letzgo.porridge.store.AudioStore
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import de.letzgo.porridge.logic.Todos
import de.letzgo.porridge.logic.TodoSuggestions
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.MoveToInbox
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.CheckBox
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
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.durationText
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import androidx.compose.runtime.produceState
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
    /** Worauf die lange Liste eingeengt ist, gewählt mit dem Knopf neben der Suche. */
    /** „More“ wurde getippt: die Liste zeigt alle Projekte, nicht nur die letzten. */
    var showAllProjects by mutableStateOf(false)
    private val scrollStates = HashMap<ListPage, LazyListState>()

    fun scroll(page: ListPage): LazyListState = scrollStates.getOrPut(page) { LazyListState() }

    fun clearSearch() { search = ""; tagTokens = emptyList(); searchKind = null }
}

/** iOS: `NotesView` (Views/Notes/NotesView.swift) — die eine lange Liste, ihre Unterseiten und darüber die Suche. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesScreen(
    list: ListState,
    onOpen: (String) -> Unit,
    /** Neue Notiz, auf Wunsch gleich in einem Projekt. */
    /** Eine neue Notiz oder ein To-do (dieselbe Notiz mit Erledigt-Stand), im offenen Bucket. */
    onNewNote: (projectID: String?, todo: Boolean) -> Unit,
    onRecord: () -> Unit,
    onSettings: () -> Unit,
    /** Plaud-Import, auf Wunsch gleich in ein Projekt. */
    onPlaud: (projectID: String?) -> Unit,
) {
    val db = PorridgeDatabase.shared
    // Bis die Datenbank geantwortet hat, ist nichts da: eine leere Liste setzte die Scroll-Position zurück.
    val loadedNotes by db.notes().observeAll().collectAsState(initial = null)
    val loadedFolders by db.folders().observeAll().collectAsState(initial = null)
    val notes = loadedNotes.orEmpty()
    val folders = loadedFolders.orEmpty()
    val loaded = loadedNotes != null && loadedFolders != null
    val page = list.page
    val openProject = (page as? ListPage.Project)?.let { p -> folders.firstOrNull { it.id == p.id } }
    val stages by ProcessingService.stages.collectAsState()
    val indexVersion by AppGraph.index.version.collectAsState()
    val coroutines = rememberCoroutineScope()
    val context = LocalContext.current
    /** Die Suche liegt als Karte über der jeweiligen Ansicht. */
    // iOS: `chatNavigation` — die Chat-Seite: welcher Chat zu sehen ist, gehalten solange die App läuft.
    val chatNavigation = remember { de.letzgo.porridge.ui.chat.ChatNavigation() }
    val chatThreads by remember { PorridgeDatabase.shared.chats().observeThreads() }.collectAsState(initial = emptyList())
    // Wohin „Zurück“ aus dem Chat und aus der Suche führt: die Seite, von der sie geöffnet wurden.
    var chatReturn by remember { mutableStateOf<ListPage>(ListPage.Home) }
    var creatingProject by remember { mutableStateOf(false) }
    /** Wohin Neues kommt: ins offene Projekt. */
    val projectForNew = (page as? ListPage.Project)?.id
    var showCreate by remember { mutableStateOf(false) }
    // Bei jedem Öffnen neu: Angemeldet wird in den Einstellungen, und eine Anmeldung kann auslaufen.
    val plaudSignedIn = remember(showCreate, page) { PlaudAccount.load().userToken != null }
    var audioImportError by remember { mutableStateOf<String?>(null) }
    val audioImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        coroutines.launch {
            runCatching { importAudio(context, uri, projectForNew) }.onSuccess { onOpen(it.id) }.onFailure { audioImportError = it.message }
        }
    }
    var showAddLink by remember { mutableStateOf(false) }
    val fileImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        coroutines.launch {
            de.letzgo.porridge.data.ShareImport.save(context.applicationContext, de.letzgo.porridge.data.ShareImport.Shared(null, null, uris), projectForNew)?.let { onOpen(it.id) }
        }
    }
    var confirmEmptyTrash by remember { mutableStateOf(false) }

    // Beim Start: Papierkorb leeren, unterbrochene Verarbeitung fortsetzen (iOS: `.task`).
    LaunchedEffect(Unit) {
        NoteStore().purgeExpired()
        // Ordner werden Projekte (einmalig; danach hat keine Notiz mehr einen Ordner).
        Projects.migrateFolders()
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
        list.page = when {
            list.page == ListPage.Chat -> chatReturn
            // Die Suche wird verlassen: Was gefragt war, ist vergessen. (Ein geöffneter Treffer behält die Seite.)
            list.page == ListPage.Search -> { list.clearSearch(); chatReturn }
            openProject?.archivedAt != null -> ListPage.Archive
            else -> ListPage.Home
        }
    }
    // Die Zurück-Geste (auch vom Rand) schließt erst die offene Karte, dann die Unterseite.
    BackHandler(enabled = page != ListPage.Home) { goBack() }
    val trash = remember(notes) { notes.filter { it.isDeleted }.sortedByDescending { it.deletedAt } }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        AnimatedContent(
            page,
            transitionSpec = { pageTransition(forward = !(targetState == ListPage.Home || (initialState is ListPage.Project && targetState == ListPage.Archive))) },
            label = "page",
        ) { shown ->
            val shownProject = (shown as? ListPage.Project)?.let { p -> folders.firstOrNull { it.id == p.id } }
            val title = when (shown) {
                ListPage.Home -> "Porridge"
                is ListPage.Project -> shownProject?.name?.ifEmpty { "Untitled Bucket" }.orEmpty()
                ListPage.Archive -> "Archive"
                ListPage.Trash -> "Recently Deleted"
                ListPage.Inbox -> "Inbox"
                ListPage.Todos -> "To-dos"
                ListPage.Chat -> "Chat"
                ListPage.Search -> "Search"
            }
            val icon: ImageVector = when (shown) {
                ListPage.Home -> Icons.Filled.Inbox
                is ListPage.Project -> Icons.Filled.Folder
                ListPage.Archive -> Icons.Filled.Archive
                ListPage.Trash -> Icons.Filled.Delete
                ListPage.Inbox -> Icons.Filled.MoveToInbox
                ListPage.Todos -> Icons.Filled.Checklist
                ListPage.Chat -> Icons.Filled.Chat
                ListPage.Search -> Icons.Filled.Search
            }
            val tint = when (shown) {
                ListPage.Home -> Brand.sky
                is ListPage.Project -> Brand.project
                ListPage.Archive -> Brand.navy
                ListPage.Trash -> Brand.danger
                ListPage.Inbox -> Brand.sky
                ListPage.Todos -> Brand.task
                ListPage.Chat -> Brand.navy
                ListPage.Search -> Brand.navy
            }
        Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            ChromeBar(title, icon, tint = tint, onBack = if (shown == ListPage.Home) null else ({ goBack() })) {
                if (shown == ListPage.Chat) de.letzgo.porridge.ui.chat.ChatBarActions(chatNavigation)
                if (shown == ListPage.Trash && trash.isNotEmpty()) IconButton(onClick = { confirmEmptyTrash = true }) { Icon(Icons.Outlined.Delete, "Delete All", tint = Brand.dangerText) }
                if (shown == ListPage.Home && trash.isNotEmpty()) IconButton(onClick = { list.page = ListPage.Trash }) { Icon(Icons.Outlined.Delete, "Recently Deleted", tint = Brand.dangerText) }
                // iOS: `importMenu` — was von außen hereinkommt, hat sein eigenes Menü in der Leiste; in einem Bucket landet es dort.
                if (shown == ListPage.Home || shownProject != null) Box {
                    var importOpen by remember { mutableStateOf(false) }
                    IconButton(onClick = { importOpen = true }) { Icon(Icons.Filled.FileDownload, "Import", tint = Brand.navy) }
                    DropdownMenu(importOpen, onDismissRequest = { importOpen = false }) {
                        DropdownMenuItem(text = { Text("Import Audio") }, leadingIcon = { Icon(Icons.Filled.GraphicEq, null) }, onClick = { importOpen = false; audioImporter.launch(arrayOf("audio/*", "video/*")) })
                        if (plaudSignedIn) DropdownMenuItem(text = { Text("Import Plaud") }, leadingIcon = { Icon(Icons.Filled.FileDownload, null) }, onClick = { importOpen = false; onPlaud(projectForNew) })
                        DropdownMenuItem(text = { Text("Photo or File") }, leadingIcon = { Icon(Icons.Filled.AttachFile, null) }, onClick = { importOpen = false; fileImporter.launch(arrayOf("image/*", "application/pdf", "text/*", "application/*")) })
                    }
                }
                if (shown == ListPage.Home) IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings", tint = Brand.navy) }
            }
            val listModifier = Modifier.weight(1f)
            val scroll = list.scroll(shown)
            when {
                !loaded -> Spacer(listModifier)
                shown == ListPage.Home -> HomeList(list, notes, folders, stages, onOpen, scroll, listModifier)
                shown is ListPage.Project ->
                    if (shownProject == null) Spacer(listModifier)
                    else ProjectDetail(shownProject, notes, stages, onOpen, scroll, listModifier)
                // iOS: `searchPage` — die Suche als eigene Seite: Ein Treffer öffnet sich daraus, zurück führt zu den Treffern.
                shown == ListPage.Search -> Box(listModifier.imePadding()) { SearchPanel(list, notes, stages, indexVersion, onOpen) }
                shown == ListPage.Chat -> de.letzgo.porridge.ui.chat.ChatPage(notes, folders, chatNavigation, onOpen, listModifier.imePadding().navigationBarsPadding())
                shown == ListPage.Inbox -> InboxList(notes, folders, stages, onOpen, scroll, listModifier)
                shown == ListPage.Todos -> TodosFolderList(notes, folders, stages, onOpen, scroll, listModifier)
                shown == ListPage.Archive -> ArchiveList(notes, folders, stages, onOpen, { list.page = ListPage.Project(it) }, scroll, listModifier)
                else -> TrashList(trash, stages, onOpen, scroll, listModifier)
            }
        }
        }
        // Derselbe Plus-Knopf auf jeder Seite, unten links die Suche (iOS: `createMenu`). In einem offenen Projekt
        // kommt alles Neue ins Projekt; die Liste bleibt, wo sie ist, das Neue öffnet sich darüber.
        // Chat und Suche sind eigene Seiten mit eigenem Feld: Die runden Knöpfe bleiben dort weg.
        if (page != ListPage.Chat && page != ListPage.Search) CreateMenu(
            showCreate, { showCreate = it },
            showsPlus = page != ListPage.Archive && page != ListPage.Trash,
            onProject = if (page == ListPage.Home) ({ creatingProject = true }) else null,
            onNote = { onNewNote(projectForNew, false) },
            onTodo = { onNewNote(projectForNew, true) },
            // iOS: Im To-do-Ordner legt das Plus gleich ein To-do an, ohne Menü.
            makesTodo = page == ListPage.Todos,
            onMeeting = onRecord, onLink = { showAddLink = true },
            onSearch = { chatReturn = page; list.page = ListPage.Search },
            // iOS: `openChat` — der Chat öffnet seine eigene Seite; aus einem Bucket geht er über diesen Bucket.
            onChat = { chatReturn = page; chatNavigation.open(projectForNew, chatThreads); list.page = ListPage.Chat },
        )
    }

    audioImportError?.let { AlertDialog(onDismissRequest = { audioImportError = null }, title = { Text("Import Failed") }, text = { Text(it) }, confirmButton = { TextButton(onClick = { audioImportError = null }) { Text("OK") } }) }
    if (showAddLink) AddLinkDialog(onDismiss = { showAddLink = false }) { address ->
        showAddLink = false
        val pid = projectForNew
        coroutines.launch {
            val note = LinkImport.add(address, project = pid)
            onOpen(note.id)
        }
    }
    if (creatingProject) TextPrompt("New Bucket", "", "Create", onDismiss = { creatingProject = false }) { name ->
        creatingProject = false
        coroutines.launch { list.page = ListPage.Project(Projects.create(name).id) }
    }
    if (confirmEmptyTrash) AlertDialog(
        onDismissRequest = { confirmEmptyTrash = false },
        title = { Text("Delete All in Recently Deleted?") },
        text = { Text("This cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmEmptyTrash = false; coroutines.launch { notes.filter { it.isDeleted }.forEach { NoteStore().deletePermanently(it) } } }) { Text("Delete All", color = Brand.dangerText) } },
        dismissButton = { TextButton(onClick = { confirmEmptyTrash = false }) { Text("Cancel") } },
    )
}

/** iOS: Startseite von `NotesView` — Projekte, Angeheftetes, dann Meetings, Notizen und Links nach Datum; am Ende Archiv und Papierkorb. */
@Composable
private fun HomeList(
    list: ListState, notes: List<Note>, folders: List<NoteFolder>, stages: Map<String, String>,
    onOpen: (String) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val projects = remember(folders, notes, list.showAllProjects) {
        HomeListLogic.shownProjects(HomeListLogic.activeProjects(folders), list.showAllProjects) { ProjectsLogic.lastChange(it, notes) }
    }
    val archiveCount = remember(folders, notes) { HomeListLogic.archiveCount(folders, notes) }
    // iOS: `InboxRow` unter der Kopfzeile „Inbox“ in `NotesView.home`.
    val waiting = remember(notes) { InboxLogic.notes(notes) }
    val todoFolder = remember(notes) { Todos.folder(notes) }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        // Der Eingang ist die erste Kategorie, mit einem Eintrag seines Namens: was neu ist oder in keinem Bucket liegt.
        // Der erste Abschnitt heißt „Up Next“: Er hält den Eingang und den To-do-Ordner; der Eintrag selbst bleibt „Inbox“.
        item(key = "h-inbox") { SectionHeader("Up Next", color = Brand.sky) }
        item(key = "row-inbox") { InboxRow(waiting) { list.page = ListPage.Inbox } }
        // Darunter der To-do-Ordner, solange es To-dos zu zeigen gibt: eine Sicht auf jedes offene, wo es auch liegt.
        if (!todoFolder.isEmpty) item(key = "row-todos") { TodoFolderRow(todoFolder) { list.page = ListPage.Todos } }
        // Die Buckets als Liste: die angepinnten und die zuletzt geänderten, der Rest hinter „More“.
        if (projects.shown.isNotEmpty()) {
            item(key = "h-projects") { SectionHeader("Buckets", color = Brand.project) }
            // Mit „More“ darunter ist die Zeile nicht die letzte.
            projectRows(projects.shown, notes, moreFollows = projects.hidden > 0) { list.page = ListPage.Project(it) }
            if (projects.hidden > 0) item(key = "more-projects") {
                MoreRow(projects.hidden, list.showAllProjects, Brand.project) { list.showAllProjects = !list.showAllProjects }
            }
        }
        if (projects.shown.isEmpty() && waiting.isEmpty() && archiveCount == 0) {
            item(key = "empty") { EmptyState("Nothing Here Yet", "Add notes, meetings, links and buckets with the plus button.", Icons.AutoMirrored.Filled.Notes) }
        }
        if (archiveCount > 0) item(key = "row-archive") { PageRow("Archive", archiveCount, Brand.navy) { list.page = ListPage.Archive } }
    }
}

/** Das Archiv: Projekte (sie lassen sich öffnen), dann Notizen nach Datum. */
@Composable
private fun ArchiveList(
    notes: List<Note>, folders: List<NoteFolder>, stages: Map<String, String>,
    onOpen: (String) -> Unit, onProject: (String) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val projects = remember(folders) { HomeListLogic.archivedProjects(folders).sortedByName() }
    val archived = remember(notes) { HomeListLogic.archivedNotes(notes) }
    if (projects.isEmpty() && archived.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("Nothing Archived", "Archive buckets and notes you are done with. They stay in the search.", Icons.Filled.Archive)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        if (projects.isNotEmpty()) {
            item(key = "h-projects") { SectionHeader("Buckets", color = Brand.project) }
            projectRows(projects, notes, onProject = onProject)
        }
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

/** iOS: `SearchPane` als Karte — Suchfeld, Arten und Tags, darunter die Treffer, auch Archiviertes. */
@Composable
private fun SearchPanel(
    list: ListState, notes: List<Note>, stages: Map<String, String>, indexVersion: Any?,
    onOpen: (String) -> Unit,
) {
    val tags = remember(notes) { tagCounts(notes.filter { !it.isDeleted }) }
    Column(Modifier.fillMaxSize()) {
        SearchBar(list.search, { list.search = it }, list.tagTokens, { list.tagTokens = it }, tags, list.searchKind, { list.searchKind = it })
        if (list.search.isNotBlank() || list.tagTokens.isNotEmpty() || list.searchKind != null) {
            SearchResults(list, notes, stages, indexVersion, onOpen, Modifier.weight(1f))
        }
    }
}

@Composable
private fun SearchResults(
    list: ListState, notes: List<Note>, stages: Map<String, String>, indexVersion: Any?,
    onOpen: (String) -> Unit, modifier: Modifier,
) {
    val query = list.search
    val tokens = list.tagTokens
    val kind = list.searchKind
    // Gesucht wird neben der Oberfläche: Bei vielen Notizen kostete sonst jeder Buchstabe einen Ruck. Das letzte
    // Ergebnis bleibt stehen, bis das neue da ist.
    val found by produceState<List<Note>?>(null, notes, query, tokens, kind, indexVersion) {
        value = withContext(Dispatchers.Default) {
            HomeListLogic.searchNotes(notes, query, tokens, kind, if (query.isBlank()) null else AppGraph.index.noteIDs(query))
        }
    }
    val foundNotes = found ?: return
    if (foundNotes.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { EmptyState("No Results", "Nothing matches your search.", Icons.Filled.Search) }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = rememberLazyListState(), contentPadding = PaddingValues(bottom = 16.dp)) {
        // iOS: Die offenen To-dos nach ihrer Fälligkeit, alles andere nach der letzten Änderung.
        if (kind == ProjectsLogic.Kind.TODO) {
            for ((title, group) in Todos.dueGroups(foundNotes)) {
                item(key = "h-$title") { SectionHeader(title, color = if (title == "Overdue") Brand.dangerText else Brand.task) }
                noteRows(group, stages, onOpen)
            }
        } else dateGroups(foundNotes, stages, onOpen)
    }
}

private fun LazyListScope.projectRows(projects: List<NoteFolder>, notes: List<Note>, moreFollows: Boolean = false, onProject: (String) -> Unit) {
    itemsIndexed(projects, key = { _, it -> "p-" + it.id }) { index, project -> ProjectRow(project, notes, showsDivider = moreFollows || index < projects.lastIndex, onOpen = onProject) }
}

private fun LazyListScope.noteRows(notes: List<Note>, stages: Map<String, String>, onOpen: (String) -> Unit) {
    // Die Überschrift darunter bringt ihre eigene Linie: Die letzte Zeile einer Gruppe zeichnet keine.
    itemsIndexed(notes, key = { _, it -> "n-" + it.id }) { index, note -> NoteSwipeRow(note, stages[note.id], onOpen, showsDivider = index < notes.lastIndex) }
}

private fun LazyListScope.dateGroups(notes: List<Note>, stages: Map<String, String>, onOpen: (String) -> Unit) {
    for ((title, group) in groups(notes)) {
        item(key = "h-$title") { SectionHeader(title) }
        noteRows(group, stages, onOpen)
    }
}

/** Klappt an Ort und Stelle auf, was die Liste weglässt. */
@Composable
private fun MoreRow(hidden: Int, expanded: Boolean, color: Color, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(if (expanded) "Less" else "More", style = MaterialTheme.typography.labelLarge, color = Brand.readable(color))
        if (!expanded) Text("$hidden", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = color, modifier = Modifier.size(18.dp))
    }
}

/** Eine Kopfzeile wie „Done“ am Ende der Liste, die zu einer Unterseite führt. */
@Composable
private fun PageRow(title: String, count: Int?, color: Color, onClick: () -> Unit) {
    SectionHeader(title, count, Modifier.clickable(onClick = onClick), color = color) {
        Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * iOS: Zeile mit Wischen — nach rechts archivieren (im Archiv zurückholen, im Papierkorb wiederherstellen), nach links
 * löschen. Anpinnen geht über das lange Drücken. [projectID]: das Projekt der offenen Seite, aus dem sie sich nehmen lässt.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun NoteSwipeRow(note: Note, stage: String?, onOpen: (String) -> Unit, projectID: String? = null, showsDivider: Boolean = true, buckets: List<String> = emptyList()) {
    val coroutines = rememberCoroutineScope()
    val store = remember { NoteStore() }
    // Der Zustand des Wischens behält seinen ersten Callback; so sieht er immer den aktuellen Stand.
    val current by rememberUpdatedState(note)
    var confirmDeleteNow by remember { mutableStateOf(false) }
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        val latest = current
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> {
                coroutines.launch {
                    when {
                        latest.isDeleted -> store.restore(latest)
                        latest.isArchived -> store.unarchive(latest)
                        else -> store.archive(latest)
                    }
                }
                // Die Zeile federt zurück: in der Suche bleibt sie stehen.
                false
            }
            SwipeToDismissBoxValue.EndToStart -> {
                if (latest.isDeleted) {
                    // Endgültig erst nach der Rückfrage; die Zeile federt zurück.
                    confirmDeleteNow = true
                    false
                } else {
                    coroutines.launch { store.trash(latest) }
                    true
                }
            }
            SwipeToDismissBoxValue.Settled -> false
        }
    })
    var menu by remember { mutableStateOf(false) }
    var dueMenu by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    if (confirmDeleteNow) AlertDialog(
        onDismissRequest = { confirmDeleteNow = false },
        title = { Text("Delete Note Now?") }, text = { Text("This cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmDeleteNow = false; coroutines.launch { store.deletePermanently(note) } }) { Text("Delete Now", color = Brand.dangerText) } },
        dismissButton = { TextButton(onClick = { confirmDeleteNow = false }) { Text("Cancel") } },
    )
    if (choosing) ProjectChooser(note.projectIDs, onToggle = { id -> coroutines.launch { Projects.toggle(note, id) } }, onDismiss = { choosing = false })
    val archived = note.isArchived
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val toStart = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier.fillMaxSize().background(if (toStart) Brand.danger else if (note.isDeleted || archived) Brand.sky else Brand.navy).padding(horizontal = 24.dp),
                contentAlignment = if (toStart) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                Icon(if (toStart) Icons.Outlined.Delete else if (note.isDeleted) Icons.Outlined.Undo else if (archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive, null, tint = if (!toStart && (note.isDeleted || archived)) Brand.onFill else Color.White)
            }
        },
    ) {
        Box {
            NoteRow(note, stage, Modifier.combinedClickable(onClick = { onOpen(note.id) }, onLongClick = { menu = true }), showsDivider, buckets)
            DueDateMenu(note, dueMenu, onDismiss = { dueMenu = false }) { key -> coroutines.launch { store.setDue(note, key) } }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (note.isDeleted) {
                    DropdownMenuItem(text = { Text("Recover") }, onClick = { menu = false; coroutines.launch { store.restore(note) } })
                    DropdownMenuItem(text = { Text("Delete Now", color = Brand.dangerText) }, onClick = { menu = false; confirmDeleteNow = true })
                } else {
                    // iOS: das lange Drücken eines To-dos hat „Mark as Done“ und das Umwandeln.
                    if (note.isTodo) DropdownMenuItem(text = { Text(if (note.isDone) "Mark as Not Done" else "Mark as Done") }, onClick = { menu = false; coroutines.launch { store.setDone(note, !note.isDone) } })
                    if (note.isTodo) DropdownMenuItem(
                        text = { Text(note.todoDue?.let { "Due ${Todos.dueLabel(it)}" } ?: "Due Date") },
                        leadingIcon = { Icon(Icons.Outlined.CalendarToday, null) },
                        onClick = { menu = false; dueMenu = true },
                    )
                    if (!archived) DropdownMenuItem(text = { Text(if (note.isPinned) "Unpin" else "Pin") }, onClick = { menu = false; coroutines.launch { NoteStore().update(note.id, touch = false) { it.copy(isPinned = !it.isPinned) } } })
                    if (note.canBeTodo) DropdownMenuItem(text = { Text(if (note.isTodo) "Convert to Note" else "Convert to To-do") }, onClick = { menu = false; coroutines.launch { store.setTodo(note, !note.isTodo) } })
                    // Ein To-do, das an einem früheren Tag erledigt wurde, ist von selbst weggeräumt: Herausholen ist hier
                    // „Mark as Not Done“ (oben), das es wieder öffnet (iOS: dieselbe Stelle heißt so).
                    if (!(note.isPutAway && note.archivedAt == null)) {
                        DropdownMenuItem(text = { Text(if (archived) "Unarchive" else "Archive") }, onClick = { menu = false; coroutines.launch { if (archived) store.unarchive(note) else store.archive(note) } })
                    }
                    DropdownMenuItem(text = { Text("Buckets…") }, onClick = { menu = false; choosing = true })
                    if (projectID != null) DropdownMenuItem(text = { Text("Remove from Bucket") }, onClick = { menu = false; coroutines.launch { Projects.toggle(note, projectID) } })
                    DropdownMenuItem(text = { Text("Delete", color = Brand.dangerText) }, onClick = { menu = false; coroutines.launch { store.trash(note) } })
                }
            }
        }
    }
}

/** iOS: `NoteRow` — Notizen in Sky, Meetings in Navy, Links in Orange. */
@Composable
internal fun NoteRow(note: Note, stage: String?, modifier: Modifier, showsDivider: Boolean = true, buckets: List<String> = emptyList()) {
    val (icon, tint) = when {
        note.isTodo -> kindIcon(note) to Brand.task
        note.isLink -> Icons.Filled.Link to LinkOrange
        note.isImage -> Icons.Filled.Image to Brand.navy
        note.isFile -> Icons.Filled.Description to Brand.navy
        note.isRecording -> Icons.Outlined.GraphicEq to Brand.navy
        note.attachmentsData != null -> Icons.Filled.AttachFile to Brand.sky
        else -> Icons.AutoMirrored.Filled.Notes to Brand.sky
    }
    // iOS: `RowThumbnail` — das erste Bild der Notiz, klein, am Ende der Zeile.
    val pictureFile = remember(note.attachmentsData) { note.attachments.firstOrNull { it.kind == de.letzgo.porridge.model.Attachment.Kind.IMAGE }?.fileName }
    val picture by androidx.compose.runtime.produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, pictureFile) {
        value = if (pictureFile == null || !AudioStore.exists(pictureFile)) null else withContext(Dispatchers.IO) {
            runCatching {
                val path = AudioStore.file(pictureFile).path
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(path, bounds)
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 320) sample *= 2
                android.graphics.BitmapFactory.decodeFile(path, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
            }.getOrNull()
        }
    }
    val coroutines = rememberCoroutineScope()
    Surface(color = MaterialTheme.colorScheme.background, modifier = modifier) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                // Jede Notiz trägt das Symbol ihrer Art; ein To-do grün mit `checklist`, gleich ob offen, erledigt oder spät.
                RowIcon(icon, tint, isPinned = note.isPinned)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        note.displayTitle, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (note.isDone) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified,
                        textDecoration = if (note.isDone) androidx.compose.ui.text.style.TextDecoration.LineThrough else null,
                    )
                    if (note.preview.isNotEmpty()) Text(note.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val footer = buildList {
                        val deletedAt = note.deletedAt
                        if (deletedAt != null) {
                            val left = NoteStore.TRASH_DAYS - TimeUnit.MILLISECONDS.toDays(System.currentTimeMillis() - deletedAt).toInt()
                            add(if (left <= 1) "Deleted tomorrow" else "$left days left")
                        // Wo ein To-do seine Buckets nennt (der To-do-Ordner), sagt seine Fälligkeit mehr: Das Datum macht ihnen Platz.
                        } else if (buckets.isEmpty() || !note.isTodo) add(SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(note.updatedAt)))
                        note.domain?.let { add(it) }
                        if (note.isRecording && note.duration > 0) add(note.duration.durationText)
                        stage?.let { add(it) } ?: if (note.status == ProcessingStatus.FAILED) add("Failed") else Unit
                    }
                    Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        // Leer (ein To-do im To-do-Ordner nennt kein Datum): kein leerer Text, der die Zeile einrückt.
                        if (footer.isNotEmpty()) Text(footer.joinToString("  ·  "), style = MaterialTheme.typography.labelSmall, color = if (note.isDeleted) Brand.danger.copy(alpha = 0.8f) else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                        if (note.isTodo) TodoDueLabel(note)
                        if (note.isTodo) TodoProgressLabel(note.todoProgress)
                        // Wo eine Liste Buckets mischt, nennt die Zeile ihre; auf schmaler Zeile weichen die Namen zuerst.
                        if (buckets.isNotEmpty()) Row(Modifier.weight(1f, fill = false), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Folder, null, tint = Brand.readable(Brand.project), modifier = Modifier.size(13.dp))
                            Text(buckets.joinToString(", "), style = MaterialTheme.typography.labelSmall, color = Brand.readable(Brand.project), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        // iOS: Eine Zusammenfassung mit wartenden Vorschlägen sagt es in der Zeile.
                        val waiting = remember(note) { TodoSuggestions.pendingFor(note, emptyList()).size }
                        if (waiting > 0) Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Checklist, null, tint = Brand.taskText, modifier = Modifier.size(13.dp))
                            Text(if (waiting == 1) "1 suggested to-do" else "$waiting suggested to-dos", style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold), color = Brand.taskText, maxLines = 1)
                        }
                    }
                }
                // iOS: Die Box, die es abhakt, steht am Ende der Zeile; ein gelöschtes zeigt sie nur.
                if (note.isTodo) Box(Modifier.align(Alignment.CenterVertically)) {
                    TodoCheckbox(note.isDone, enabled = !note.isDeleted) { coroutines.launch { NoteStore().setDone(note, !note.isDone) } }
                }
                picture?.let { bitmap ->
                    androidx.compose.foundation.Image(
                        bitmap, null, Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                    )
                }
            }
            if (showsDivider) HorizontalDivider(Modifier.padding(start = 76.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
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
        // Kalendertage, nicht 24-Stunden-Stücke: In der Woche der Zeitumstellung hat ein Tag 23 oder 25 Stunden.
        val days = java.time.temporal.ChronoUnit.DAYS.between(
            java.time.Instant.ofEpochMilli(day.timeInMillis).atZone(java.time.ZoneId.systemDefault()).toLocalDate(),
            java.time.Instant.ofEpochMilli(today.timeInMillis).atZone(java.time.ZoneId.systemDefault()).toLocalDate(),
        ).toInt()
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
    onNote: () -> Unit, onTodo: () -> Unit, onMeeting: () -> Unit, onLink: () -> Unit,
    makesTodo: Boolean = false,
    /** Die Wahl für die lange Liste; null, wo es den Knopf nicht gibt. */
    onSearch: () -> Unit, onChat: () -> Unit,
) {
    BackHandler(enabled = open) { onOpen(false) }
    // Andere Seite oder offene Karte: die Arten klappen wieder ein.
    Box(Modifier.fillMaxSize()) {
        if (open) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.08f)).combinedClickableNoRipple { onOpen(false) })
        // iOS: Chat und Suche unten links; jede öffnet ihre eigene Seite.
        Row(Modifier.align(Alignment.BottomStart).navigationBarsPadding().padding(start = 22.dp, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SkyFab(Icons.Filled.Chat, "Chat", container = MaterialTheme.colorScheme.surfaceContainerHigh, content = Brand.navy) { onOpen(false); onChat() }
            SkyFab(Icons.Filled.Search, "Search", container = MaterialTheme.colorScheme.surfaceContainerHigh, content = Brand.navy) { onOpen(false); onSearch() }
        }
        if (showsPlus) Column(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(end = 22.dp, bottom = 16.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            AnimatedVisibility(open) {
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (onProject != null) CreateOption("Bucket", Icons.Filled.Folder, Brand.project) { onOpen(false); onProject() }

                    CreateOption("Link", Icons.Filled.Link, LinkOrange) { onOpen(false); onLink() }
                    CreateOption("Meeting", Icons.Filled.Mic, Brand.navy) { onOpen(false); onMeeting() }
                    CreateOption("To-do", Icons.Filled.Checklist, Brand.task) { onOpen(false); onTodo() }
                    CreateOption("Note", Icons.Outlined.EditNote, Brand.sky) { onOpen(false); onNote() }
                }
            }
            SkyFab(Icons.Filled.Add, if (open) "Close" else if (makesTodo) "New To-do" else "Create", Modifier.rotate(if (open) 45f else 0f)) {
                if (makesTodo && !open) onTodo() else onOpen(!open)
            }
        }
    }
}

/** Eine gewählte Audio- oder Videodatei wird ein Meeting, das transkribiert wird. */
private suspend fun importAudio(context: android.content.Context, uri: android.net.Uri, projectID: String?): Note {
    val name = context.contentResolver.query(uri, null, null, null, null)?.use { c ->
        val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
        if (c.moveToFirst() && i >= 0) c.getString(i) else null
    } ?: "Import"
    // Kopieren und Ausmessen nicht auf dem Thread der Oberfläche: Eine Stunde Video sind hunderte Megabyte.
    val (fileName, info) = withContext(Dispatchers.IO) {
        val copied = AudioStore.importFile(context, uri, name.substringAfterLast('.', "m4a"))
        copied to AudioStore.audioInfo(copied)
    }
    val note = Note(
        title = name.substringBeforeLast('.'), titleIsCustom = true, statusRaw = ProcessingStatus.RECORDED.raw,
        audioFileName = fileName, inputName = "Import", duration = info?.first ?: 0.0, channelCount = info?.second ?: 1,
        projectIDs = listOfNotNull(projectID), sourceRaw = de.letzgo.porridge.model.NoteSource.AUDIO_IMPORT.raw,
    )
    PorridgeDatabase.shared.notes().upsert(note)
    ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
    return note
}

@Composable
private fun CreateOption(title: String, icon: ImageVector, tint: Color, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, shadowElevation = 6.dp, color = MaterialTheme.colorScheme.surface) {
        Row(Modifier.heightIn(min = 48.dp).padding(start = 16.dp, end = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = Brand.readable(tint), modifier = Modifier.size(22.dp))
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

/** iOS: `InboxRow` — der Eingang als der eine Eintrag seiner Kategorie, mit eigenem Symbol. */
@Composable
private fun InboxRow(waiting: List<Note>, onOpen: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        RowIcon(Icons.Filled.MoveToInbox, Brand.sky)
        Column(Modifier.weight(1f)) {
            Text("Inbox", style = MaterialTheme.typography.bodyLarge, maxLines = 1)
            Text(
                if (waiting.isEmpty()) "Nothing waiting" else "${waiting.size} waiting",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
            )
        }
    }
}

/** iOS: `TodoFolderRow` — der To-do-Ordner als Eintrag im Abschnitt „Up Next“: wie viele offen sind und wie viele zu spät. */
@Composable
private fun TodoFolderRow(folder: Todos.Folder, onOpen: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        RowIcon(Icons.Filled.Checklist, Brand.task)
        Column(Modifier.weight(1f)) {
            Text("To-dos", style = MaterialTheme.typography.bodyLarge, maxLines = 1)
            Row {
                Text(
                    if (folder.open == 0) "Nothing open" else "${folder.open} open",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                )
                if (folder.overdue > 0) {
                    Text(" · ", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("${folder.overdue} overdue", style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold), color = Brand.dangerText, maxLines = 1)
                }
            }
        }
    }
}

/**
 * iOS: `NotesView.todosPage` — der To-do-Ordner geöffnet: jedes offene To-do nach Fälligkeit, gruppiert wie „Open To-dos“
 * der Suche, dann die heute erledigten. Jede Zeile nennt ihre Buckets. Nur eine Sicht: Die To-dos bleiben, wo sie sind.
 */
@Composable
private fun TodosFolderList(
    notes: List<Note>, folders: List<NoteFolder>, stages: Map<String, String>, onOpen: (String) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val folder = remember(notes) { Todos.folder(notes) }
    val names = remember(folders) { folders.associate { it.id to it.name } }
    fun buckets(note: Note) = note.projectIDs.mapNotNull { names[it]?.ifEmpty { "Untitled Bucket" } }
    if (folder.isEmpty) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("Nothing to Do", "Open to-dos from the inbox and every bucket show up here.", Icons.Filled.Checklist)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        for ((title, group) in folder.groups) {
            item(key = "h-$title") { SectionHeader(title, group.size, color = if (title == "Overdue") Brand.dangerText else Brand.task) }
            itemsIndexed(group, key = { _, it -> "n-" + it.id }) { index, note -> NoteSwipeRow(note, stages[note.id], onOpen, showsDivider = index < group.lastIndex, buckets = buckets(note)) }
        }
        if (folder.doneToday.isNotEmpty()) {
            item(key = "h-done") { SectionHeader("Done Today", folder.doneToday.size, color = Brand.navy) }
            itemsIndexed(folder.doneToday, key = { _, it -> "d-" + it.id }) { index, note -> NoteSwipeRow(note, stages[note.id], onOpen, showsDivider = index < folder.doneToday.lastIndex, buckets = buckets(note)) }
        }
    }
}

/** iOS: `NotesView.inboxPage` — der Eingang geöffnet: was in keinem Bucket liegt, neueste zuerst, je mit den Ablage-Knöpfen. */
@Composable
private fun InboxList(
    notes: List<Note>, folders: List<NoteFolder>, stages: Map<String, String>, onOpen: (String) -> Unit, state: LazyListState, modifier: Modifier,
) {
    val waiting = remember(notes) { InboxLogic.notes(notes) }
    val buckets = remember(folders) { folders.filter { it.archivedAt == null && it.name.isNotBlank() }.sortedBy { it.name.lowercase() } }
    if (waiting.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("Inbox Empty", "What is new or in no bucket waits here.", Icons.Filled.MoveToInbox)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
        for (note in waiting) {
            val suggests = note.suggestedProjectIDs.any { id -> buckets.any { it.id == id } }
            item(key = "in-" + note.id) { NoteSwipeRow(note, stages[note.id], onOpen, showsDivider = !suggests) }
            if (suggests) item(key = "f-" + note.id) { FilingBar(note, buckets) }
        }
    }
}

/** Die vorgeschlagenen Buckets eines Eintrags im Eingang; jeder andere Bucket steckt im langen Druck der Zeile (iOS: `FilingBar.swift`). */
@Composable
fun FilingBar(note: Note, folders: List<NoteFolder>, modifier: Modifier = Modifier.padding(start = 76.dp, end = 20.dp, bottom = 10.dp)) {
    val coroutines = rememberCoroutineScope()
    val store = remember { NoteStore() }
    Row(modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        for (folder in note.suggestedProjectIDs.mapNotNull { id -> folders.firstOrNull { it.id == id } }) {
            AssistChip(
                onClick = { coroutines.launch { store.file(note, folder.id) } },
                label = { Text(folder.name, maxLines = 1) },
                leadingIcon = { Icon(Icons.Filled.AutoAwesome, "Suggested bucket", Modifier.size(16.dp)) },
                trailingIcon = { Icon(Icons.Filled.Close, "Drop Suggestion", Modifier.size(16.dp).clickable { coroutines.launch { store.dismissSuggestions(note) } }) },
                colors = AssistChipDefaults.assistChipColors(containerColor = Brand.project, labelColor = Color.White, leadingIconContentColor = Color.White, trailingIconContentColor = Color.White),
            )
        }
    }
}

package de.letzgo.porridge.ui.projects

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.logic.ProjectsLogic.Element
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.RowIcon
import de.letzgo.porridge.ui.components.SkyFab
import de.letzgo.porridge.ui.notes.NoteRow
import de.letzgo.porridge.ui.notes.TextPrompt
import de.letzgo.porridge.ui.tasks.TaskRow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS: `ProjectsPane` — alle Projekte; ein getipptes zeigt seine Notizen, Meetings, Links und Aufgaben.
 * Das offene Projekt ([open]) hält die Wurzel, damit es bleibt, während eine Notiz daraus offen ist.
 */
@Composable
fun ProjectsScreen(
    projects: List<NoteFolder>,
    open: NoteFolder?,
    notes: List<Note>,
    items: List<ActionItem>,
    stages: Map<String, String>,
    onProject: (String?) -> Unit,
    onOpen: (String) -> Unit,
    onEditTask: (ActionItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxWidth()) {
        if (open == null) ProjectList(projects, notes, items, onProject)
        else ProjectDetail(open, notes, items, stages, onBack = { onProject(null) }, onOpen = onOpen, onEditTask = onEditTask)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectList(projects: List<NoteFolder>, notes: List<Note>, items: List<ActionItem>, onProject: (String?) -> Unit) {
    val coroutines = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<NoteFolder?>(null) }
    var deleting by remember { mutableStateOf<NoteFolder?>(null) }
    val sorted = remember(projects) { projects.sortedByName() }
    // Je Projekt: Anzahl und letzte Änderung (eigene oder die des neuesten Eintrags).
    val stats = remember(projects, notes, items) {
        projects.associate { p ->
            val elements = ProjectsLogic.elements(p.id, notes, items)
            p.id to (elements.size to maxOf(p.updatedAt, p.createdAt, elements.maxOfOrNull { it.date } ?: 0))
        }
    }
    if (sorted.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            EmptyState("No Projects Yet", "Group notes, meetings, links and tasks into projects. Tap the plus button to start one.", Icons.Filled.Folder)
        }
    } else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 110.dp)) {
        items(sorted, key = { it.id }) { project ->
            var menu by remember { mutableStateOf(false) }
            val (count, changed) = stats[project.id] ?: (0 to project.updatedAt)
            Box {
                Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.combinedClickable(onClick = { onProject(project.id) }, onLongClick = { menu = true })) {
                    Column {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            RowIcon(Icons.Filled.Folder, Brand.project)
                            Column(Modifier.weight(1f)) {
                                Text(project.name.ifEmpty { "Untitled Project" }, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    listOf(if (count == 1) "1 item" else "$count items", SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(changed))).joinToString("  ·  "),
                                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                                )
                            }
                        }
                        HorizontalDivider(Modifier.padding(start = 58.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = project })
                    DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { menu = false; deleting = project })
                }
            }
        }
    }
    renaming?.let { p ->
        TextPrompt("Rename Project", p.name, "Save", onDismiss = { renaming = null }) { name -> renaming = null; coroutines.launch { Projects.rename(p, name) } }
    }
    deleting?.let { p ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete project “${p.name}”?") },
            text = { Text("Its notes, meetings, links and tasks stay; they are only no longer in this project.") },
            confirmButton = { TextButton(onClick = { deleting = null; coroutines.launch { Projects.delete(p) } }) { Text("Delete", color = Brand.danger) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectDetail(
    project: NoteFolder, notes: List<Note>, items: List<ActionItem>, stages: Map<String, String>,
    onBack: () -> Unit, onOpen: (String) -> Unit, onEditTask: (ActionItem) -> Unit,
) {
    val coroutines = rememberCoroutineScope()
    val store = remember { ActionItemStore() }
    /** null = alles. */
    var filter by remember { mutableStateOf<ProjectsLogic.Kind?>(null) }
    LaunchedEffect(project.id) { filter = null }
    val all = remember(project.id, notes, items) { ProjectsLogic.elements(project.id, notes, items) }
    val shown = filter?.let { k -> all.filter { it.kind == k } } ?: all
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = Brand.project, modifier = Modifier.padding(end = 4.dp))
                Text("Projects", color = Brand.project)
            }
            val chips = listOf<ProjectsLogic.Kind?>(null) + ProjectsLogic.Kind.entries
            for (kind in chips) {
                val count = kind?.let { k -> all.count { it.kind == k } } ?: all.size
                FilterChip(
                    selected = filter == kind, onClick = { filter = kind },
                    label = { Text("${kind?.title ?: "All"} $count") },
                    colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Brand.project.copy(alpha = 0.18f), selectedLabelColor = Brand.navy),
                )
            }
        }
        if (shown.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                EmptyState(
                    "Nothing Here Yet", "Add notes, meetings, links or tasks to this project from their page, or tap the plus button for a new note.",
                    Icons.Filled.FolderOpen,
                )
            }
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 110.dp)) {
            items(shown, key = { it.id }) { element ->
                when (element) {
                    is Element.NoteElement -> {
                        var menu by remember { mutableStateOf(false) }
                        var choosing by remember { mutableStateOf(false) }
                        if (choosing) ProjectChooser(
                            element.note.projectIDs, onToggle = { id -> coroutines.launch { Projects.toggle(element.note, id) } },
                            onDismiss = { choosing = false },
                        )
                        Box {
                            NoteRow(element.note, stages[element.note.id], Modifier.combinedClickable(onClick = { onOpen(element.note.id) }, onLongClick = { menu = true }))
                            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text("Projects…") }, onClick = { menu = false; choosing = true })
                                DropdownMenuItem(text = { Text("Remove from Project") }, onClick = { menu = false; coroutines.launch { Projects.toggle(element.note, project.id) } })
                            }
                        }
                    }
                    is Element.TaskElement -> TaskRow(
                        element.item, element.note, onOpen = onOpen, onEdit = onEditTask,
                        onToggle = { coroutines.launch { store.setDone(element.item, !element.item.isDone) } },
                        onDelete = { coroutines.launch { store.delete(element.item) } },
                        onAccept = { coroutines.launch { store.accept(listOf(element.item)) } },
                        onDismiss = { coroutines.launch { store.dismiss(element.item) } },
                    )
                }
            }
        }
    }
}

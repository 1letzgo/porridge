package de.letzgo.porridge.ui.projects

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.RowIcon
import de.letzgo.porridge.ui.notes.NoteSwipeRow
import de.letzgo.porridge.ui.notes.TextPrompt
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS: `ProjectRow` — ein Projekt als Ordnerzeile, auf der Startseite und im Archiv: nach rechts wischen archiviert
 * (im Archiv: holt zurück), langes Drücken bietet dazu Umbenennen und Löschen.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun ProjectRow(project: NoteFolder, notes: List<Note>, onOpen: (String) -> Unit) {
    val coroutines = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    // Anzahl und letzte Änderung (eigene oder die des neuesten Eintrags).
    val (count, changed) = remember(project, notes) {
        ProjectsLogic.elements(project.id, notes).size to ProjectsLogic.lastChange(project, notes)
    }
    val archived = project.archivedAt != null
    fun toggleArchive() { coroutines.launch { if (project.archivedAt != null) Projects.unarchive(project) else Projects.archive(project) } }
    // Der Zustand des Wischens behält seinen ersten Callback; so sieht er immer den aktuellen Stand.
    val swipeArchive by rememberUpdatedState(::toggleArchive)
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        if (value == SwipeToDismissBoxValue.StartToEnd) swipeArchive()
        false
    })
    SwipeToDismissBox(
        swipe, enableDismissFromEndToStart = false,
        backgroundContent = {
            Box(Modifier.fillMaxSize().background(if (archived) Brand.sky else Brand.navy).padding(horizontal = 24.dp), contentAlignment = Alignment.CenterStart) {
                Icon(if (archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive, null, tint = Color.White)
            }
        },
    ) {
        Box {
            Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.combinedClickable(onClick = { onOpen(project.id) }, onLongClick = { menu = true })) {
                Column {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        RowIcon(Icons.Filled.Folder, Brand.project)
                        Column(Modifier.weight(1f)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                if (project.isPinned) Icon(Icons.Filled.PushPin, "Pinned", tint = Color(0xFFF2994A), modifier = Modifier.size(12.dp))
                                Text(project.name.ifEmpty { "Untitled Project" }, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
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
                if (!archived) DropdownMenuItem(text = { Text(if (project.isPinned) "Unpin" else "Pin") }, onClick = { menu = false; coroutines.launch { Projects.togglePin(project) } })
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = true })
                DropdownMenuItem(text = { Text(if (archived) "Unarchive" else "Archive") }, onClick = { menu = false; toggleArchive() })
                DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { menu = false; deleting = true })
            }
        }
    }
    if (renaming) TextPrompt("Rename Project", project.name, "Save", onDismiss = { renaming = false }) { name -> renaming = false; coroutines.launch { Projects.rename(project, name) } }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text("Delete project “${project.name}”?") },
        text = { Text("Its notes, meetings and links stay; they are only no longer in this project.") },
        confirmButton = { TextButton(onClick = { deleting = false; coroutines.launch { Projects.delete(project) } }) { Text("Delete", color = Brand.danger) } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } },
    )
}

/** iOS: Detailseite von `ProjectsPane` — die nicht archivierten Notizen, Meetings und Links eines Projekts, mit Chips nach Art. */
@Composable
internal fun ProjectDetail(
    project: NoteFolder, notes: List<Note>, stages: Map<String, String>,
    onOpen: (String) -> Unit, state: LazyListState, modifier: Modifier = Modifier,
) {
    /** null = alles. */
    var filter by remember { mutableStateOf<ProjectsLogic.Kind?>(null) }
    LaunchedEffect(project.id) { filter = null }
    val all = remember(project.id, notes) { ProjectsLogic.elements(project.id, notes) }
    val shown = filter?.let { k -> all.filter { ProjectsLogic.kind(it) == k } } ?: all
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val chips = listOf<ProjectsLogic.Kind?>(null) + ProjectsLogic.Kind.entries
            for (kind in chips) {
                val count = kind?.let { k -> all.count { ProjectsLogic.kind(it) == k } } ?: all.size
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
                    "Nothing Here Yet", "Add notes, meetings or links to this project from their page, or tap the plus button for a new note.",
                    Icons.Filled.FolderOpen,
                )
            }
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize(), state = state, contentPadding = PaddingValues(bottom = 110.dp)) {
            items(shown, key = { it.id }) { note -> NoteSwipeRow(note, stages[note.id], onOpen, projectID = project.id) }
        }
    }
}

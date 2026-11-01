package de.letzgo.porridge.ui.tasks

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalContext
import de.letzgo.porridge.model.NoteText
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.data.Me
import de.letzgo.porridge.logic.HomeListLogic
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.SectionHeader
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.ui.projects.ProjectChooser
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS: `TaskSections` (Views/Tasks/TasksPane.swift) — die Aufgaben als Abschnitte einer Liste: New, Mine, General,
 * dann Done eingeklappt. Abhaken hier hakt auch die Zeile in der Zusammenfassung ab; ein Tipp öffnet die Aufgabe als
 * eigene Seite.
 */
fun LazyListScope.taskSections(
    tasks: List<Pair<ActionItem, Note?>>, showDone: Boolean, onShowDone: (Boolean) -> Unit,
    onOpen: (String) -> Unit, onEdit: (ActionItem) -> Unit,
) {
    val (new, mine, general, done) = HomeListLogic.sections(tasks, Me.names)
    fun rows(list: List<Pair<ActionItem, Note?>>) = items(list, key = { "t-" + it.first.id }) { (item, note) -> TaskListRow(item, note, onOpen, onEdit) }
    if (new.isNotEmpty()) {
        item(key = "h-tasks-new") {
            val coroutines = rememberCoroutineScope()
            SectionHeader("New", new.size, color = Brand.task) {
                TextButton(onClick = { coroutines.launch { ActionItemStore().accept(new.map { it.first }) } }) {
                    Text("Accept All", color = Brand.task, style = MaterialTheme.typography.labelLarge)
                }
            }
        }
        rows(new)
    }
    if (mine.isNotEmpty()) {
        item(key = "h-tasks-mine") { SectionHeader("Mine", mine.size, color = Brand.task) }
        rows(mine)
    }
    if (general.isNotEmpty()) {
        item(key = "h-tasks-general") { SectionHeader("General", general.size, color = Brand.task) }
        rows(general)
    }
    if (done.isNotEmpty()) {
        item(key = "h-tasks-done") {
            val rotation by animateFloatAsState(if (showDone) 90f else 0f, label = "chevron")
            SectionHeader("Done", done.size, Modifier.clickable { onShowDone(!showDone) }, color = Brand.task) {
                Icon(Icons.Filled.ChevronRight, if (showDone) "Hide" else "Show", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.rotate(rotation))
            }
        }
        if (showDone) rows(done)
    }
}

/** Eine Aufgabe mit allem, was sich in ihrer Zeile tun lässt. */
@Composable
internal fun TaskListRow(item: ActionItem, note: Note?, onOpen: (String) -> Unit, onEdit: (ActionItem) -> Unit) {
    val coroutines = rememberCoroutineScope()
    val store = remember { ActionItemStore() }
    TaskRow(
        item, note, onOpen = onOpen, onEdit = onEdit,
        onToggle = { coroutines.launch { store.setDone(item, !item.isDone) } },
        onDelete = { coroutines.launch { store.delete(item) } },
        onAccept = { coroutines.launch { store.accept(listOf(item)) } },
        onDismiss = { coroutines.launch { store.dismiss(item) } },
        onArchive = { coroutines.launch { if (item.archivedAt != null) store.unarchive(item) else store.archive(item) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun TaskRow(
    item: ActionItem, note: Note?, onOpen: (String) -> Unit, onEdit: (ActionItem) -> Unit, onToggle: () -> Unit, onDelete: () -> Unit,
    onAccept: () -> Unit, onDismiss: () -> Unit, onArchive: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    val coroutines = rememberCoroutineScope()
    if (choosing) ProjectChooser(
        item.projectIDs, onToggle = { id -> coroutines.launch { Projects.toggle(item, id) } }, onDismiss = { choosing = false },
        inherited = note?.projectIDs.orEmpty(),
    )
    val context = LocalContext.current
    val review = item.needsReview
    // Der Zustand des Wischens behält seinen ersten Callback; so sieht er immer den aktuellen Stand.
    val isReview by rememberUpdatedState(review)
    val delete by rememberUpdatedState(onDelete)
    val accept by rememberUpdatedState(onAccept)
    val dismiss by rememberUpdatedState(onDismiss)
    val archive by rememberUpdatedState(onArchive)
    // Eine neue Aufgabe: nach rechts übernehmen, nach links verwerfen. Sonst nach rechts archivieren, nach links löschen.
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.EndToStart -> { if (isReview) dismiss() else delete(); true }
            // Die Zeile federt zurück: sie zieht um oder bleibt (in der Suche), statt leer stehen zu bleiben.
            SwipeToDismissBoxValue.StartToEnd -> { if (isReview) accept() else archive(); false }
            else -> false
        }
    })
    SwipeToDismissBox(
        swipe,
        backgroundContent = {
            if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) {
                Box(Modifier.fillMaxSize().background(if (review) Brand.task else if (item.archivedAt != null) Brand.sky else Brand.navy).padding(start = 24.dp), contentAlignment = Alignment.CenterStart) {
                    when {
                        review -> Icon(Icons.Filled.Check, "Accept", tint = androidx.compose.ui.graphics.Color.White)
                        item.archivedAt != null -> Icon(Icons.Outlined.Unarchive, "Unarchive", tint = androidx.compose.ui.graphics.Color.White)
                        else -> Icon(Icons.Outlined.Archive, "Archive", tint = androidx.compose.ui.graphics.Color.White)
                    }
                }
            } else {
                Box(Modifier.fillMaxSize().background(Brand.danger).padding(end = 24.dp), contentAlignment = Alignment.CenterEnd) {
                    if (review) Icon(Icons.Filled.Close, "Dismiss", tint = androidx.compose.ui.graphics.Color.White)
                    else Icon(Icons.Outlined.Delete, "Delete", tint = androidx.compose.ui.graphics.Color.White)
                }
            }
        },
    ) {
        Column(Modifier.background(MaterialTheme.colorScheme.background)) {
            Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 20.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.Top) {
                IconButton(onClick = onToggle) {
                    Icon(if (item.isDone) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank, if (item.isDone) "Mark as Open" else "Mark as Done", tint = Brand.task)
                }
                Box(Modifier.weight(1f)) {
                    Column(
                        Modifier.fillMaxWidth().combinedClickable(onClick = { onEdit(item) }, onLongClick = { menu = true }).padding(top = 10.dp, bottom = 6.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            item.text.ifEmpty { "Untitled Task" }, style = MaterialTheme.typography.bodyLarge,
                            color = if (item.isDone || item.text.isEmpty()) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                            textDecoration = if (item.isDone) TextDecoration.LineThrough else null,
                        )
                        val details = NoteText.plainLines(item.details).joinToString(" ")
                        if (details.isNotEmpty()) Text(details, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            item.owner?.let {
                                Surface(shape = RoundedCornerShape(50), color = Brand.task.copy(alpha = 0.18f)) {
                                    Text(it, style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold), color = Brand.navy, modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp))
                                }
                            }
                            val date = SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(note?.createdAt ?: item.createdAt))
                            Text(
                                note?.let { "${it.displayTitle} · $date" } ?: date,
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        if (review) {
                            DropdownMenuItem(text = { Text("Accept") }, onClick = { menu = false; onAccept() })
                            DropdownMenuItem(text = { Text("Dismiss") }, onClick = { menu = false; onDismiss() })
                            HorizontalDivider()
                        }
                        DropdownMenuItem(text = { Text("Open Task") }, onClick = { menu = false; onEdit(item) })
                        note?.let { n -> DropdownMenuItem(text = { Text("Open Note") }, onClick = { menu = false; onOpen(n.id) }) }
                        DropdownMenuItem(text = { Text("Projects…") }, onClick = { menu = false; choosing = true })
                        DropdownMenuItem(text = { Text("Copy") }, onClick = {
                            menu = false
                            val clipboard = context.getSystemService(android.content.ClipboardManager::class.java)
                            clipboard?.setPrimaryClip(android.content.ClipData.newPlainText("Task", item.line))
                        })
                        DropdownMenuItem(text = { Text(if (item.archivedAt != null) "Unarchive" else "Archive") }, onClick = { menu = false; onArchive() })
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("Delete", color = Brand.danger) }, onClick = { menu = false; onDelete() })
                    }
                }
                if (review) {
                    IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "Dismiss", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick = onAccept) { Icon(Icons.Filled.Check, "Accept", tint = Brand.task) }
                }
            }
            HorizontalDivider(Modifier.padding(start = 56.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

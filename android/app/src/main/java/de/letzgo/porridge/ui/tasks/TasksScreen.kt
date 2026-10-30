package de.letzgo.porridge.ui.tasks

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Delete
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.SectionHeader
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS: `TasksPane` (Views/Tasks/TasksPane.swift) — alle Aufgaben: aus den Zusammenfassungen und von Hand
 * angelegte, offen zuerst, dann erledigt. Abhaken hier hakt auch die Zeile in der Zusammenfassung ab; ein Tipp
 * öffnet die Aufgabe als eigene Seite.
 */
@Composable
fun TasksScreen(items: List<ActionItem>, notes: List<Note>, onOpen: (String) -> Unit, onEdit: (ActionItem) -> Unit, modifier: Modifier = Modifier) {
    val byID = notes.associateBy { it.id }
    // Eine Aufgabe, deren Notiz weg ist, bleibt eigenständig; Seiten geben keine Aufgaben.
    val tasks = items.mapNotNull { item ->
        if (item.kind != ActionItem.Kind.TASK || item.review == ActionItem.Review.DISMISSED) return@mapNotNull null
        val note = item.noteID?.let { byID[it] } ?: return@mapNotNull Triple(item, null, item.createdAt)
        if (note.isDeleted || note.isLink) null else Triple(item, note, note.createdAt)
    }.sortedWith(compareByDescending<Triple<ActionItem, Note?, Long>> { it.third }.thenBy { it.first.order }).map { it.first to it.second }
    val new = tasks.filter { it.first.needsReview }
    val open = tasks.filter { !it.first.isDone && !it.first.needsReview }
    val done = tasks.filter { it.first.isDone }
    var showDone by remember { mutableStateOf(false) }
    val coroutines = rememberCoroutineScope()
    val store = remember { ActionItemStore() }
    val rotation by animateFloatAsState(if (showDone) 90f else 0f, label = "chevron")

    if (tasks.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("No Tasks Yet", "Tasks come from the summaries of your meetings and notes, or you add one with the plus button.", Icons.Filled.Checklist)
        }
        return
    }
    @Composable
    fun row(item: ActionItem, note: Note?) = TaskRow(
        item, note, onOpen = onOpen, onEdit = onEdit,
        onToggle = { coroutines.launch { store.setDone(item, !item.isDone) } },
        onDelete = { coroutines.launch { store.delete(item) } },
        onAccept = { coroutines.launch { store.accept(listOf(item)) } },
        onDismiss = { coroutines.launch { store.dismiss(item) } },
    )
    LazyColumn(modifier.fillMaxWidth(), contentPadding = PaddingValues(bottom = 96.dp)) {
        if (new.isNotEmpty()) {
            item {
                SectionHeader("New", new.size, color = Brand.task) {
                    TextButton(onClick = { coroutines.launch { store.accept(new.map { it.first }) } }) {
                        Text("Accept All", color = Brand.task, style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
            items(new, key = { it.first.id }) { (item, note) -> row(item, note) }
        }
        if (open.isNotEmpty()) {
            item { SectionHeader("Open", open.size, color = Brand.task) }
            items(open, key = { it.first.id }) { (item, note) -> row(item, note) }
        }
        if (done.isNotEmpty()) {
            item {
                SectionHeader("Done", done.size, Modifier.clickable { showDone = !showDone }, color = Brand.task) {
                    Icon(Icons.Filled.ChevronRight, if (showDone) "Hide" else "Show", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.rotate(rotation))
                }
            }
            if (showDone) items(done, key = { it.first.id }) { (item, note) -> row(item, note) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun TaskRow(
    item: ActionItem, note: Note?, onOpen: (String) -> Unit, onEdit: (ActionItem) -> Unit, onToggle: () -> Unit, onDelete: () -> Unit,
    onAccept: () -> Unit, onDismiss: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val review = item.needsReview
    // Eine neue Aufgabe: nach rechts übernehmen, nach links verwerfen. Sonst nach links löschen.
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.EndToStart -> { if (review) onDismiss() else onDelete(); true }
            SwipeToDismissBoxValue.StartToEnd -> { if (review) onAccept(); review }
            else -> false
        }
    })
    SwipeToDismissBox(
        swipe, enableDismissFromStartToEnd = review,
        backgroundContent = {
            if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) {
                Box(Modifier.fillMaxSize().background(Brand.task).padding(start = 24.dp), contentAlignment = Alignment.CenterStart) {
                    Icon(Icons.Filled.Check, "Accept", tint = androidx.compose.ui.graphics.Color.White)
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
                        DropdownMenuItem(text = { Text("Copy") }, onClick = {
                            menu = false
                            val clipboard = context.getSystemService(android.content.ClipboardManager::class.java)
                            clipboard?.setPrimaryClip(android.content.ClipData.newPlainText("Task", item.line))
                        })
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

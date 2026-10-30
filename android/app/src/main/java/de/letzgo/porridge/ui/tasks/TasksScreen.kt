package de.letzgo.porridge.ui.tasks

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
 * iOS: `TasksPane` (Views/Tasks/TasksPane.swift) — alle Aufgaben aus den Zusammenfassungen: offen zuerst, dann
 * erledigt, je mit ihrer Notiz. Abhaken hier hakt auch die Zeile in der Zusammenfassung ab.
 */
@Composable
fun TasksScreen(items: List<ActionItem>, notes: List<Note>, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val byID = notes.associateBy { it.id }
    val tasks = items.mapNotNull { item ->
        val note = item.noteID?.let { byID[it] }?.takeIf { item.kind == ActionItem.Kind.TASK && !it.isDeleted } ?: return@mapNotNull null
        item to note
    }.sortedWith(compareByDescending<Pair<ActionItem, Note>> { it.second.createdAt }.thenBy { it.first.order })
    val open = tasks.filter { !it.first.isDone }
    val done = tasks.filter { it.first.isDone }
    var showDone by remember { mutableStateOf(false) }
    val coroutines = rememberCoroutineScope()
    val store = remember { ActionItemStore() }
    val rotation by animateFloatAsState(if (showDone) 90f else 0f, label = "chevron")

    if (tasks.isEmpty()) {
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState("No Tasks Yet", "Tasks come from the summaries of your meetings and notes. Summarize a meeting and its action items show up here.", Icons.Filled.Checklist)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), contentPadding = PaddingValues(bottom = 32.dp)) {
        if (open.isNotEmpty()) {
            item { SectionHeader("Open", open.size) }
            items(open, key = { it.first.id }) { (item, note) -> TaskRow(item, note, onOpen) { coroutines.launch { store.setDone(item, !item.isDone) } } }
        }
        if (done.isNotEmpty()) {
            item {
                SectionHeader("Done", done.size, Modifier.clickable { showDone = !showDone }) {
                    Icon(Icons.Filled.ChevronRight, if (showDone) "Hide" else "Show", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.rotate(rotation))
                }
            }
            if (showDone) items(done, key = { it.first.id }) { (item, note) -> TaskRow(item, note, onOpen) { coroutines.launch { store.setDone(item, !item.isDone) } } }
        }
    }
}

@Composable
private fun TaskRow(item: ActionItem, note: Note, onOpen: (String) -> Unit, onToggle: () -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 20.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.Top) {
            IconButton(onClick = onToggle) {
                Icon(if (item.isDone) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank, if (item.isDone) "Mark as Open" else "Mark as Done", tint = Brand.sky)
            }
            Column(Modifier.weight(1f).clickable { onOpen(note.id) }.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    item.text, style = MaterialTheme.typography.bodyLarge,
                    color = if (item.isDone) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    textDecoration = if (item.isDone) TextDecoration.LineThrough else null,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    item.owner?.let {
                        Surface(shape = RoundedCornerShape(50), color = Brand.sky.copy(alpha = 0.18f)) {
                            Text(it, style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold), color = Brand.navy, modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp))
                        }
                    }
                    Text(
                        "${note.displayTitle} · ${SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(note.createdAt))}",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        HorizontalDivider(Modifier.padding(start = 56.dp), thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
    }
}

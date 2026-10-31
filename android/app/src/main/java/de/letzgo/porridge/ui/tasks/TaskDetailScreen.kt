package de.letzgo.porridge.ui.tasks

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.notes.NoteBodyEditor
import de.letzgo.porridge.ui.notes.NoteEditorController
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.ui.projects.ProjectPills
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.filled.Folder
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS: `TaskDetailView` (Views/Tasks/TaskDetailView.swift) — eine Aufgabe als eigene Seite: Titel, erledigt,
 * wer zuständig ist, woher sie stammt, und ihr eigener Text (derselbe Editor wie bei Notizen).
 * Titel, Zuständiger und Text werden lokal gehalten und gespeichert; Echos aus der Datenbank überschreiben sie nicht.
 */
@Composable
fun TaskDetailScreen(id: String, onOpenNote: (String) -> Unit, onClose: () -> Unit) {
    val db = PorridgeDatabase.shared
    val store = remember { ActionItemStore() }
    val coroutines = rememberCoroutineScope()
    val saveLock = remember { Mutex() }
    val stored by db.actionItems().observe(id).collectAsState(initial = null)
    var loaded by remember { mutableStateOf(false) }
    var title by remember { mutableStateOf("") }
    var owner by remember { mutableStateOf("") }
    var details by remember { mutableStateOf("") }
    var confirmDelete by remember { mutableStateOf(false) }
    val editor = remember { NoteEditorController() }
    val titleFocus = remember { FocusRequester() }

    LaunchedEffect(id) {
        val item = db.actionItems().get(id) ?: return@LaunchedEffect onClose()
        title = item.text; owner = item.owner.orEmpty(); details = item.details
        loaded = true
    }
    // Eine neue Aufgabe startet im Titel; erst nachdem das Feld da ist.
    LaunchedEffect(loaded) { if (loaded && title.isEmpty()) runCatching { titleFocus.requestFocus() } }
    val note by (stored?.noteID?.let { db.notes().observe(it) } ?: kotlinx.coroutines.flow.flowOf(null)).collectAsState(initial = null)

    /** Schreibt die lokalen Felder in den gespeicherten Eintrag (abhaken läuft getrennt über den Store). */
    fun save(change: (ActionItem) -> ActionItem) {
        coroutines.launch {
            saveLock.withLock {
                val current = db.actionItems().get(id) ?: return@withLock
                store.save(change(current))
            }
        }
    }

    fun close() {
        editor.blur()
        coroutines.launch { store.dropEmptyManual(); onClose() }
    }
    BackHandler { close() }

    val item = stored
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { close() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Done", tint = Brand.navy) }
                Text("Task", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold), color = Brand.navy)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.Delete, "Delete", tint = Brand.danger) }
            }
            if (item == null || !loaded) return@Column
            Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    IconButton(onClick = { coroutines.launch { store.setDone(item, !item.isDone) } }) {
                        Icon(
                            if (item.isDone) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                            if (item.isDone) "Mark as Open" else "Mark as Done", tint = Brand.task, modifier = Modifier.size(28.dp),
                        )
                    }
                    Box(Modifier.weight(1f).padding(top = 10.dp)) {
                        val style = MaterialTheme.typography.titleLarge.copy(
                            fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface,
                            textDecoration = if (item.isDone) TextDecoration.LineThrough else null,
                        )
                        if (title.isEmpty()) Text("Task", style = style.copy(color = MaterialTheme.colorScheme.onSurfaceVariant))
                        BasicTextField(
                            value = title, onValueChange = { v -> val t = v.replace("\n", " "); title = t; save { it.copy(text = t) } },
                            textStyle = style, cursorBrush = SolidColor(Brand.task),
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
                            modifier = Modifier.fillMaxWidth().focusRequester(titleFocus),
                        )
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Person, null, tint = Brand.task, modifier = Modifier.padding(horizontal = 12.dp).size(22.dp))
                    Box(Modifier.weight(1f)) {
                        val style = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface)
                        if (owner.isEmpty()) Text("Responsible", style = style.copy(color = MaterialTheme.colorScheme.onSurfaceVariant))
                        BasicTextField(
                            value = owner, singleLine = true, textStyle = style, cursorBrush = SolidColor(Brand.task),
                            onValueChange = { v -> owner = v; save { it.copy(owner = v.trim().ifEmpty { null }) } },
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                note?.takeIf { !it.isDeleted }?.let { n ->
                    Row(
                        Modifier.fillMaxWidth().clickable { editor.blur(); onOpenNote(n.id) }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Outlined.Description, "Open Note", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 12.dp).size(22.dp))
                        Text(
                            "${n.displayTitle} · ${SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(n.createdAt))}",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                        )
                        Spacer(Modifier.width(4.dp))
                        Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                    }
                }
                // Projekte: eigene und, blass, die der Notiz.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Folder, "Projects", tint = Brand.project, modifier = Modifier.padding(horizontal = 12.dp).size(22.dp))
                    Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ProjectPills(
                            item.projectIDs, { pid -> coroutines.launch { Projects.toggle(item, pid) } },
                            inherited = ProjectsLogic.inherited(item, note?.takeIf { !it.isDeleted }),
                        )
                    }
                }
                HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                NoteBodyEditor(
                    details, { text -> details = text; save { it.copy(details = text) } }, editor,
                    Modifier.fillMaxWidth().weight(1f).heightIn(min = 280.dp), placeholder = "Notes",
                )
            }
        }
    }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this task?") },
        confirmButton = {
            TextButton(onClick = {
                confirmDelete = false
                coroutines.launch { stored?.let { store.delete(it) }; onClose() }
            }) { Text("Delete", color = Brand.danger) }
        },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

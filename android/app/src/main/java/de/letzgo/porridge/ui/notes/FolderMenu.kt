package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Notes
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.NoteScope
import de.letzgo.porridge.model.tree
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import kotlinx.coroutines.launch

/** iOS: `FolderMenu` (Views/Notes/FolderMenu.swift) — wählt, was die Liste zeigt, und verwaltet Ordner. */
@Composable
fun FolderMenu(notes: List<Note>, folders: List<NoteFolder>, scope: NoteScope, onScope: (NoteScope) -> Unit) {
    var open by remember { mutableStateOf(false) }
    var showTags by remember { mutableStateOf(false) }
    var prompt by remember { mutableStateOf<FolderPrompt?>(null) }
    val live = notes.filter { !it.isDeleted }
    val folderIDs = folders.map { it.id }.toSet()

    IconButton(onClick = { open = true }) { Icon(Icons.Outlined.Folder, contentDescription = "Folders", tint = Brand.navy) }
    DropdownMenu(expanded = open, onDismissRequest = { open = false; showTags = false }) {
        @Composable fun item(title: String, count: Int, target: NoteScope, icon: androidx.compose.ui.graphics.vector.ImageVector, indent: Int = 0) =
            DropdownMenuItem(
                text = { Text("$title ($count)") },
                leadingIcon = { Icon(if (scope == target) Icons.Filled.Check else icon, null) },
                onClick = { onScope(target); open = false },
                modifier = Modifier.padding(start = (indent * 14).dp),
            )
        item("All Notes", live.size, NoteScope.All, Icons.Outlined.Inbox)
        item("Notes", live.count { it.folderID == null || it.folderID !in folderIDs }, NoteScope.Unfiled, Icons.Outlined.Notes)
        for ((folder, depth) in folders.tree()) item(folder.name, live.count { it.folderID == folder.id }, NoteScope.Folder(folder.id), Icons.Outlined.Folder, depth)
        val tags = tagCounts(live)
        if (tags.isNotEmpty()) {
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Tags") }, leadingIcon = { Icon(Icons.Outlined.Tag, null) }, onClick = { showTags = !showTags })
            if (showTags) for ((tag, count) in tags) item("#$tag", count, NoteScope.Tag(tag.lowercase()), Icons.Outlined.Tag, 1)
        }
        HorizontalDivider()
        item("Recently Deleted", notes.count { it.isDeleted }, NoteScope.Trash, Icons.Outlined.Delete)
        HorizontalDivider()
        DropdownMenuItem(text = { Text("New Folder") }, leadingIcon = { Icon(Icons.Outlined.CreateNewFolder, null) }, onClick = { prompt = FolderPrompt.Create(null); open = false })
        if (scope is NoteScope.Folder) {
            val folder = folders.firstOrNull { it.id == scope.id }
            if (folder != null) {
                DropdownMenuItem(text = { Text("New Subfolder") }, leadingIcon = { Icon(Icons.Outlined.CreateNewFolder, null) }, onClick = { prompt = FolderPrompt.Create(folder.id); open = false })
                DropdownMenuItem(text = { Text("Rename Folder") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { prompt = FolderPrompt.Rename(folder); open = false })
                DropdownMenuItem(text = { Text("Delete Folder") }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { prompt = FolderPrompt.Delete(folder); open = false })
            }
        }
    }
    prompt?.let { FolderPromptDialog(it, onScope) { prompt = null } }
}

/** Tags mit Anzahl, häufigste zuerst (iOS: `FolderMenu.tagCounts`). */
fun tagCounts(notes: List<Note>): List<Pair<String, Int>> {
    val counts = LinkedHashMap<String, Pair<String, Int>>()
    for (note in notes) for (tag in note.tags) {
        val key = tag.lowercase()
        counts[key] = (counts[key]?.first ?: tag) to ((counts[key]?.second ?: 0) + 1)
    }
    return counts.values.sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first.lowercase() })
}

sealed interface FolderPrompt {
    data class Create(val parentID: String?) : FolderPrompt
    data class Rename(val folder: NoteFolder) : FolderPrompt
    data class Delete(val folder: NoteFolder) : FolderPrompt
}

@Composable
private fun FolderPromptDialog(prompt: FolderPrompt, onScope: (NoteScope) -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val db = PorridgeDatabase.shared
    var name by remember { mutableStateOf((prompt as? FolderPrompt.Rename)?.folder?.name.orEmpty()) }
    when (prompt) {
        is FolderPrompt.Delete -> AlertDialog(
            onDismissRequest = onDone,
            title = { Text("Delete “${prompt.folder.name}”?") },
            text = { Text("The notes in it move to Recently Deleted.") },
            confirmButton = { TextButton(onClick = { scope.launch { NoteStore().delete(prompt.folder); onScope(NoteScope.All) }; onDone() }) { Text("Delete Folder", color = Brand.danger) } },
            dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
        )
        else -> AlertDialog(
            onDismissRequest = onDone,
            title = { Text(if (prompt is FolderPrompt.Rename) "Rename Folder" else "New Folder") },
            text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, label = { Text("Name") }) },
            confirmButton = {
                TextButton(enabled = name.isNotBlank(), onClick = {
                    scope.launch {
                        when (prompt) {
                            is FolderPrompt.Create -> NoteFolder(name = name.trim(), parentID = prompt.parentID).also { db.folders().upsert(it); onScope(NoteScope.Folder(it.id)) }
                            is FolderPrompt.Rename -> db.folders().upsert(prompt.folder.copy(name = name.trim()))
                            else -> Unit
                        }
                    }
                    onDone()
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
        )
    }
}

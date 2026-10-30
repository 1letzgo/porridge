package de.letzgo.porridge.ui.notes

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteScope
import de.letzgo.porridge.ui.Brand

/**
 * iOS: `TagMenu` (Views/Notes/TagMenu.swift) — der Filter nach Tag in der Leiste: alle, jeder Tag mit Anzahl und,
 * wo Notizen stehen, „Recently Deleted“. Derselbe in Aufgaben, Meetings, Notizen und Links. Ein gewählter Tag
 * füllt den Knopf mit der Farbe der Ansicht ([tint]).
 */
@Composable
fun TagMenu(notes: List<Note>, scope: NoteScope, onScope: (NoteScope) -> Unit, showsTrash: Boolean = false, deletedCount: Int = 0, tint: Color = Brand.sky, iconTint: Color = Brand.navy) {
    var open by remember { mutableStateOf(false) }
    val filtered = scope is NoteScope.Tag
    if (filtered) {
        FilledIconButton(onClick = { open = true }, colors = IconButtonDefaults.filledIconButtonColors(containerColor = tint, contentColor = Color.White)) {
            Icon(Icons.Outlined.Tag, contentDescription = "Filter by Tag, active")
        }
    } else {
        IconButton(onClick = { open = true }) { Icon(Icons.Outlined.Tag, contentDescription = "Filter by Tag", tint = iconTint) }
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        @Composable fun item(title: String, target: NoteScope, icon: androidx.compose.ui.graphics.vector.ImageVector) =
            DropdownMenuItem(
                text = { Text(title) },
                leadingIcon = { Icon(if (scope == target) Icons.Filled.Check else icon, null) },
                onClick = { onScope(target); open = false },
            )
        item("All", NoteScope.All, Icons.Outlined.Inbox)
        val tags = tagCounts(notes.filter { !it.isDeleted })
        if (tags.isNotEmpty()) {
            HorizontalDivider()
            for ((tag, count) in tags) item("#$tag ($count)", NoteScope.Tag(tag.lowercase()), Icons.Outlined.Tag)
        }
        if (showsTrash) {
            HorizontalDivider()
            item("Recently Deleted ($deletedCount)", NoteScope.Trash, Icons.Outlined.Delete)
        }
    }
}

/** Tags mit Anzahl, häufigste zuerst (iOS: `TagMenu.tagCounts`). */
fun tagCounts(notes: List<Note>): List<Pair<String, Int>> {
    val counts = LinkedHashMap<String, Pair<String, Int>>()
    for (note in notes) for (tag in note.tags) {
        val key = tag.lowercase()
        counts[key] = (counts[key]?.first ?: tag) to ((counts[key]?.second ?: 0) + 1)
    }
    return counts.values.sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first.lowercase() })
}

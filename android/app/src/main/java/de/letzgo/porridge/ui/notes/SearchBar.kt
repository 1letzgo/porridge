package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.model.Note

/**
 * iOS: `SearchPane` + `TimelineSearchBar` — Suchfeld, darunter eine Art zur Wahl (Meetings, Notes, Links) und
 * die Tags, gewählte als Marken. Tags gibt es nur hier.
 */
@Composable
fun SearchBar(
    text: String, onText: (String) -> Unit, tokens: List<String>, onTokens: (List<String>) -> Unit, tags: List<Pair<String, Int>>,
    kind: ProjectsLogic.Kind?, onKind: (ProjectsLogic.Kind?) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = text, onValueChange = onText, singleLine = true, placeholder = { Text("Search") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = { if (text.isNotEmpty()) IconButton(onClick = { onText("") }) { Icon(Icons.Filled.Close, "Clear text") } },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            for (k in listOf(ProjectsLogic.Kind.MEETING, ProjectsLogic.Kind.NOTE, ProjectsLogic.Kind.LINK)) {
                FilterChip(selected = kind == k, onClick = { onKind(if (kind == k) null else k) }, label = { Text(k.title) })
            }
            for (token in tokens) InputChip(selected = true, onClick = { onTokens(tokens - token) }, label = { Text("#$token") }, trailingIcon = { Icon(Icons.Filled.Close, "Remove #$token") })
            for ((tag, count) in tags) if (tag.lowercase() !in tokens) AssistChip(onClick = { onTokens(tokens + tag.lowercase()) }, label = { Text("#$tag  $count") })
        }
        if (text.isBlank() && tokens.isEmpty() && kind == null) {
            Text("Search your notes, meetings and links, archived ones too.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(20.dp))
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

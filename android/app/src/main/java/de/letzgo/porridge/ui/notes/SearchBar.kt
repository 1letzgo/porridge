package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.ui.components.SectionHeader

/** iOS: `SearchPane` + `TimelineSearchBar` — Suchfeld mit gewählten Tags als Marken; ohne Anfrage die Tag-Liste. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SearchBar(text: String, onText: (String) -> Unit, tokens: List<String>, onTokens: (List<String>) -> Unit, tags: List<Pair<String, Int>>) {
    Column(Modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = text, onValueChange = onText, singleLine = true, placeholder = { Text("Search") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = { if (text.isNotEmpty()) IconButton(onClick = { onText("") }) { Icon(Icons.Filled.Close, "Clear text") } },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        if (tokens.isNotEmpty()) {
            FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (token in tokens) InputChip(selected = true, onClick = { onTokens(tokens - token) }, label = { Text("#$token") }, trailingIcon = { Icon(Icons.Filled.Close, "Remove #$token") })
            }
        }
        if (text.isBlank() && tokens.isEmpty()) {
            if (tags.isEmpty()) {
                Text("Type a word to search your notes and meetings. Tags show up here once you have some.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(20.dp))
            } else {
                SectionHeader("Tags")
                FlowRow(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((tag, count) in tags) AssistChip(onClick = { onTokens(tokens + tag.lowercase()) }, label = { Text("#$tag  $count") })
                }
            }
        }
    }
}

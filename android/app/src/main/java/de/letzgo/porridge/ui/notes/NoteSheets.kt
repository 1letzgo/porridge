package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.path
import de.letzgo.porridge.model.tree
import de.letzgo.porridge.store.NoteMerger
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** iOS: `SummaryEditorSheet` — die Zusammenfassung als Markdown bearbeiten. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SummaryEditorSheet(initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    ModalBottomSheet(onDismissRequest = { onSave(text) }) {
        Column(Modifier.fillMaxWidth().padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Summary", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Cancel") }
                TextButton(onClick = { onSave(text) }) { Text("Done") }
            }
            OutlinedTextField(value = text, onValueChange = { text = it }, modifier = Modifier.fillMaxWidth().heightIn(min = 240.dp, max = 520.dp))
        }
    }
}

/** iOS: `MergeNotesSheet` — andere aufgenommene Notizen in diese einfügen. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MergeNotesSheet(base: Note, onDismiss: () -> Unit, onMerged: () -> Unit) {
    val notes by PorridgeDatabase.shared.notes().observeAll().collectAsState(initial = emptyList())
    val candidates = notes.filter { it.id != base.id && !it.isDeleted && it.isRecording && it.status == ProcessingStatus.READY }
    var picked by remember { mutableStateOf(setOf<String>()) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val coroutines = rememberCoroutineScope()
    ModalBottomSheet(onDismissRequest = { if (!working) onDismiss() }) {
        Column(Modifier.fillMaxWidth().padding(16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Merge with …", style = MaterialTheme.typography.titleLarge)
            Text("The transcripts are joined in time order, speakers are matched and the recordings combined. The other notes are deleted.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (candidates.isEmpty()) Text("There are no other recordings to merge.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            LazyColumn(Modifier.heightIn(max = 400.dp)) {
                items(candidates, key = { it.id }) { note ->
                    val on = note.id in picked
                    Row(Modifier.fillMaxWidth().clickable { picked = if (on) picked - note.id else picked + note.id }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (on) Icons.Filled.CheckCircle else Icons.Outlined.Circle, null, tint = if (on) Brand.sky else MaterialTheme.colorScheme.onSurfaceVariant)
                        Column(Modifier.padding(start = 12.dp)) {
                            Text(note.displayTitle, maxLines = 1)
                            Text(SimpleDateFormat("d MMM yyyy, HH:mm", Locale.getDefault()).format(Date(note.createdAt)), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            error?.let { Text(it, color = Brand.danger) }
            Button(
                enabled = picked.isNotEmpty() && !working, modifier = Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = Brand.sky),
                onClick = {
                    working = true
                    coroutines.launch {
                        runCatching { NoteMerger().merge(candidates.filter { it.id in picked }, base) }
                            .onSuccess { onMerged(); onDismiss() }
                            .onFailure { error = it.message }
                        working = false
                    }
                },
            ) { if (working) CircularProgressIndicator(Modifier.padding(2.dp), color = androidx.compose.ui.graphics.Color.White, strokeWidth = 2.dp) else Text("Merge ${picked.size} into this note") }
        }
    }
}

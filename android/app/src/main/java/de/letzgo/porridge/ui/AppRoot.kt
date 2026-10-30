package de.letzgo.porridge.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.BuildConfig
import de.letzgo.porridge.data.AppUpdate
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.store.NoteStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.launch

/**
 * Hülle bis die Bildschirme aus Track F (NotesScreen, NoteDetailScreen, Settings …) da sind: zeigt die
 * Notizen, legt leere an und prüft auf Updates. iOS: `NotesView` (stark vereinfacht).
 */
@Composable
fun AppRoot() {
    val db = PorridgeDatabase.shared
    val notes by db.notes().observeAll().collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    var manualResult by remember { mutableStateOf<String?>(null) }
    var manualRelease by remember { mutableStateOf<AppUpdate.Release?>(null) }

    AppUpdateCheck()
    manualRelease?.let { AppUpdateDialog(it) { manualRelease = null } }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        floatingActionButton = {
            FloatingActionButton(
                onClick = { scope.launch { NoteStore().save(Note()) } },
                containerColor = Brand.sky,
                contentColor = Color.White,
            ) { Icon(Icons.Filled.Add, contentDescription = "New Note") }
        },
    ) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(top = padding.calculateTopPadding() + 16.dp, bottom = 96.dp)) {
            item {
                Text("All Notes", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.padding(horizontal = 20.dp))
                Spacer(Modifier.height(12.dp))
            }
            items(notes.filter { !it.isDeleted }, key = { it.id }) { note ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                    Text(note.displayTitle, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (note.preview.isNotEmpty()) {
                        Text(note.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
                HorizontalDivider(Modifier.padding(start = 20.dp), color = MaterialTheme.colorScheme.outlineVariant)
            }
            item {
                Column(Modifier.padding(20.dp)) {
                    Text("ABOUT", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.secondary)
                    Text("Porridge ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", style = MaterialTheme.typography.bodyMedium)
                    if (BuildConfig.SIDELOAD) {
                        TextButton(onClick = {
                            scope.launch {
                                manualResult = null
                                runCatching { AppUpdate.checkManually() }
                                    .onSuccess { if (it == null) manualResult = "Porridge ${BuildConfig.VERSION_NAME} is up to date." else manualRelease = it }
                                    .onFailure { manualResult = "Could not check: ${it.message}" }
                            }
                        }) { Text("Check for Updates") }
                        manualResult?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

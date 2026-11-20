package de.letzgo.porridge.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.AppGraph
import de.letzgo.porridge.cloud.ChatService
import de.letzgo.porridge.model.ChatEntry
import de.letzgo.porridge.model.ChatThread
import androidx.compose.material.icons.filled.Description
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.MarkdownText
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val examples = listOf("What did we decide in the last meetings?", "Which tasks are still open?", "Summarize what came in this week")

private fun scopeName(project: String?, folders: List<NoteFolder>): String =
    if (project == null) "All Buckets" else folders.firstOrNull { it.id == project }?.name?.ifEmpty { "Untitled Bucket" } ?: "Deleted Bucket"

/**
 * iOS: `ChatNavigation` — wo die Chat-Seite steht: welcher Chat zu sehen ist, oder die Liste aller. Die Liste hält es,
 * solange die App läuft, damit die Leiste der Seite (ihre Knöpfe) und die Seite dasselbe sehen.
 */
class ChatNavigation {
    /** Der Chat, der zu sehen ist; null ist ein neuer, den es erst mit seiner ersten Frage gibt. */
    var openID by mutableStateOf<String?>(null)
    var showsList by mutableStateOf(false)
    /** Worüber ein neuer Chat geht; null ist alles. */
    var newScope by mutableStateOf<String?>(null)
    /** Der Bucket, aus dem der Chat geöffnet wurde: Ein neuer Chat geht über ihn. */
    var project by mutableStateOf<String?>(null)

    /** Der letzte Chat über das, was offen ist, wird wieder aufgenommen; sonst beginnt ein neuer. */
    fun open(from: String?, threads: List<ChatThread>) {
        project = from
        newScope = from
        showsList = false
        openID = threads.firstOrNull { it.projectID == from }?.id
    }

    fun startNew() {
        openID = null
        newScope = project
        showsList = false
    }
}

/** iOS: `ChatBarActions` — die Knöpfe in der Leiste der Chat-Seite: die Liste aller Chats und ein neuer Chat. */
@Composable
fun ChatBarActions(navigation: ChatNavigation) {
    val threads by remember { PorridgeDatabase.shared.chats().observeThreads() }.collectAsState(initial = emptyList())
    if (threads.isNotEmpty()) IconButton(onClick = { navigation.showsList = !navigation.showsList }) {
        Icon(if (navigation.showsList) Icons.Filled.Chat else Icons.AutoMirrored.Filled.List, if (navigation.showsList) "Back to Chat" else "All Chats", tint = Brand.navy)
    }
    if (navigation.openID != null || navigation.showsList) IconButton(onClick = { navigation.startNew() }) { Icon(Icons.Filled.Edit, "New Chat", tint = Brand.navy) }
}

/**
 * iOS: `ChatPage` (Views/Chat/ChatView.swift) — der Chat als eigene Seite, erreicht über seinen Knopf unten links: ein
 * Chat oder die Liste aller. Chats werden gehalten.
 */
@Composable
fun ChatPage(notes: List<Note>, folders: List<NoteFolder>, navigation: ChatNavigation, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val chats = remember { PorridgeDatabase.shared.chats() }
    val threads by remember { chats.observeThreads() }.collectAsState(initial = emptyList())
    val coroutines = rememberCoroutineScope()
    val open = threads.firstOrNull { it.id == navigation.openID }
    Column(modifier.fillMaxSize()) {
        if (navigation.showsList) {
            LazyColumn(Modifier.fillMaxSize()) {
                items(threads, key = { it.id }) { thread ->
                    Row(
                        Modifier.fillMaxWidth().clickable { navigation.openID = thread.id; navigation.showsList = false }.padding(start = 20.dp, top = 6.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(thread.title.ifEmpty { "New Chat" }, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                scopeName(thread.projectID, folders) + "  ·  " + SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(thread.updatedAt)),
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                            )
                        }
                        if (thread.id == navigation.openID) Icon(Icons.Filled.Check, null, tint = Brand.navy, modifier = Modifier.size(18.dp))
                        IconButton(onClick = { coroutines.launch { ChatService.delete(thread); if (navigation.openID == thread.id) navigation.openID = null } }) {
                            Icon(Icons.Filled.Delete, "Delete Chat", tint = Brand.dangerText)
                        }
                    }
                }
            }
        } else {
            Chat(open, notes, folders, navigation.newScope, { navigation.newScope = it }, onOpen) { navigation.openID = it.id }
        }
    }
}

/** iOS: `ChatView` — ein Chat mit den Notizen: Die Fragen beantwortet das in den Einstellungen gewählte Modell aus den passenden Passagen. */
@Composable
private fun Chat(
    thread: ChatThread?, notes: List<Note>, folders: List<NoteFolder>, scope: String?, onScope: (String?) -> Unit,
    onOpen: (String) -> Unit, onCreate: (ChatThread) -> Unit,
) {
    val chats = remember { PorridgeDatabase.shared.chats() }
    val entries by remember(thread?.id) { thread?.let { chats.observeEntries(it.id) } ?: kotlinx.coroutines.flow.flowOf(emptyList()) }.collectAsState(initial = emptyList())
    val thinking by ChatService.thinking.collectAsState()
    val status by ChatService.status.collectAsState()
    val isThinking = thread != null && thinking == thread.id
    var input by rememberSaveable(thread?.id) { mutableStateOf("") }
    val state = rememberLazyListState()
    val scopeOfAll = remember { AppGraph.scope }

    fun send(text: String) {
        val question = text.trim()
        if (question.isEmpty() || thinking != null) return
        input = ""
        // Ein neuer Chat wird von seiner ersten Frage an gehalten.
        val chat = thread ?: ChatThread(projectID = scope).also(onCreate)
        scopeOfAll.launch {
            if (thread == null) chats.upsert(chat)
            ChatService.ask(question, chat, notes, folders)
        }
    }

    LaunchedEffect(entries.size, isThinking) { if (entries.isNotEmpty()) state.animateScrollToItem(entries.size + 1) }
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = state, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            // Worüber der Chat geht. Ein neuer kann noch wählen; ein gehaltener bleibt bei dem, womit er begann.
            item(key = "scope") {
                Box {
                    var choosing by remember { mutableStateOf(false) }
                    AssistChip(
                        onClick = { if (thread == null) choosing = true },
                        label = { Text(scopeName(thread?.projectID ?: scope.takeIf { thread == null }, folders), maxLines = 1) },
                        leadingIcon = { Icon(Icons.Filled.Folder, null, Modifier.size(16.dp), tint = Brand.readable(Brand.project)) },
                        trailingIcon = if (thread == null) ({ Icon(Icons.Filled.ExpandMore, "Chat About", Modifier.size(16.dp)) }) else null,
                    )
                    DropdownMenu(choosing, onDismissRequest = { choosing = false }) {
                        DropdownMenuItem(text = { Text("All Buckets") }, onClick = { choosing = false; onScope(null) })
                        for (folder in folders.filter { it.archivedAt == null }.sortedBy { it.name.lowercase() }) {
                            DropdownMenuItem(text = { Text(folder.name.ifEmpty { "Untitled Bucket" }) }, onClick = { choosing = false; onScope(folder.id) })
                        }
                    }
                }
            }
            if (entries.isEmpty()) {
                item(key = "intro") {
                    Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("Ask Your Buckets", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        Text(
                            "Ask about anything in your notes, meetings, links, images and files. The answer comes from your own data.",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 6.dp, start = 12.dp, end = 12.dp),
                        )
                    }
                }
                items(examples, key = { it }) { example ->
                    Text(
                        example, color = Brand.navy,
                        modifier = Modifier.fillMaxWidth().background(Brand.sky.copy(alpha = 0.14f), RoundedCornerShape(14.dp)).clickable { send(example) }.padding(12.dp),
                    )
                }
            }
            items(entries, key = { it.id }) { entry -> Bubble(entry, notes, onOpen) }
            if (isThinking) item(key = "thinking") {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text(status.ifEmpty { "Thinking…" }, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item(key = "end") { Spacer(Modifier.size(1.dp)) }
        }
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, bottom = 12.dp, top = 4.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(input, { input = it }, placeholder = { Text("Ask your buckets…") }, maxLines = 4, shape = RoundedCornerShape(16.dp), modifier = Modifier.weight(1f))
            IconButton(onClick = { send(input) }, enabled = input.isNotBlank() && thinking == null) {
                Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = if (input.isNotBlank() && thinking == null) Brand.navy else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun Bubble(entry: ChatEntry, notes: List<Note>, onOpen: (String) -> Unit) {
    if (entry.isUser) {
        Box(Modifier.fillMaxWidth().padding(start = 48.dp), contentAlignment = Alignment.CenterEnd) {
            Text(entry.text, modifier = Modifier.background(Brand.sky.copy(alpha = 0.18f), RoundedCornerShape(16.dp)).padding(12.dp))
        }
        return
    }
    Column(Modifier.fillMaxWidth().padding(end = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (entry.isError) Text(entry.text, color = Brand.dangerText) else MarkdownText(entry.text)
        val sources = remember(entry.sourcesData) { ChatService.sources(entry) }
        if (sources.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // iOS: das Symbol der Art der Notiz, aus der die Stelle stammt (eine Seite, wenn sie weg ist).
            for (source in sources) AssistChip(
                onClick = { onOpen(source.noteID) }, label = { Text(source.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                leadingIcon = { androidx.compose.material3.Icon(notes.firstOrNull { it.id == source.noteID }?.let { de.letzgo.porridge.ui.notes.kindIcon(it) } ?: androidx.compose.material.icons.Icons.Filled.Description, null, modifier = Modifier.size(16.dp)) },
            )
        }
    }
}

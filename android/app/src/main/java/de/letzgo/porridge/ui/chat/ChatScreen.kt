package de.letzgo.porridge.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.AppGraph
import de.letzgo.porridge.logic.ChatMessage
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.components.EmptyState
import de.letzgo.porridge.ui.components.MarkdownText
import kotlinx.coroutines.launch

/** iOS: `ChatView` (Views/Chat/ChatView.swift) — Fragen an die eigenen Notizen; Antworten nennen ihre Quellen. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ChatScreen(notes: List<Note>, items: List<ActionItem>, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val chat = AppGraph.chat
    val messages by chat.messages.collectAsState()
    val thinking by chat.isThinking.collectAsState()
    val status by chat.status.collectAsState()
    var input by remember { mutableStateOf("") }
    val coroutines = rememberCoroutineScope()
    val list = rememberLazyListState()
    LaunchedEffect(messages.size, thinking) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size) }

    Column(modifier.fillMaxWidth().imePadding()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (messages.isEmpty() && !thinking) {
                EmptyState("Ask Your Notes", "Ask about your meetings, notes and saved pages. Answers name the notes they come from.", Icons.Filled.ChatBubble, Modifier.align(Alignment.Center))
            }
            LazyColumn(state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(messages, key = { it.id }) { message ->
                    val mine = message.role == ChatMessage.Role.USER
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
                        Column(
                            Modifier.widthIn(max = 520.dp).clip(RoundedCornerShape(18.dp))
                                .background(if (mine) Brand.sky else MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 14.dp, vertical = 10.dp),
                        ) {
                            if (mine) Text(message.text, color = androidx.compose.ui.graphics.Color.White)
                            else if (message.isError) Text(message.text, color = Brand.danger)
                            else MarkdownText(message.text)
                            if (message.sources.isNotEmpty()) {
                                FlowRow(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    for (source in message.sources) AssistChip(onClick = { onOpen(source.noteID) }, label = { Text(source.title, maxLines = 1) })
                                }
                            }
                        }
                    }
                }
                if (thinking) item {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(Modifier.padding(4.dp), strokeWidth = 2.dp, color = Brand.sky)
                        Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(value = input, onValueChange = { input = it }, placeholder = { Text("Ask your notes …") }, modifier = Modifier.weight(1f), maxLines = 5, shape = RoundedCornerShape(22.dp))
            IconButton(enabled = input.isNotBlank() && !thinking, onClick = {
                val question = input
                input = ""
                coroutines.launch { chat.ask(question, notes, items) }
            }) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand.sky) }
        }
    }
}

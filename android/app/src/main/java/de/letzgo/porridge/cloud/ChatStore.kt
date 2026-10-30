package de.letzgo.porridge.cloud

import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SummaryBilling
import de.letzgo.porridge.logic.ActionItemsLogic
import de.letzgo.porridge.logic.ChatChunk
import de.letzgo.porridge.logic.ChatMessage
import de.letzgo.porridge.logic.ChatPrompt
import de.letzgo.porridge.logic.SummaryException
import de.letzgo.porridge.ml.TextModels
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Woher der Chat seine Passagen bekommt (`index/NoteIndex.kt`). */
interface ChatContextSource {
    suspend fun refresh(notes: List<Note>)
    suspend fun search(question: String, budget: Int): List<ChatChunk>
    fun recent(budget: Int): List<ChatChunk>
}

/** iOS: `ChatStore` (Services/ChatService.swift) — das Gespräch mit den Notizen, solange die App läuft. */
class ChatStore(private val index: ChatContextSource) {
    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()
    private val _isThinking = MutableStateFlow(false)
    val isThinking: StateFlow<Boolean> = _isThinking.asStateFlow()
    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status.asStateFlow()

    fun reset() {
        if (!_isThinking.value) _messages.value = emptyList()
    }

    suspend fun ask(question: String, notes: List<Note>, items: List<ActionItem> = emptyList()) {
        val q = question.trim()
        if (q.isEmpty() || _isThinking.value) return
        val history = _messages.value.takeLast(4)
        _messages.value = _messages.value + ChatMessage(ChatMessage.Role.USER, q)
        _isThinking.value = true
        _status.value = "Searching your notes …"
        try {
            index.refresh(notes)
            // Aufgaben und Entscheidungen gehen immer mit: „was ist noch offen?“ braucht die Liste, nicht Passagen.
            val tasks = ActionItemsLogic.contextBlock(items, notes, 2200)
            var context = index.search(q, 6500 - tasks.length)
            if (context.isEmpty()) context = index.recent(4500 - tasks.length)
            if (context.isEmpty()) {
                _messages.value = _messages.value + ChatMessage(ChatMessage.Role.ASSISTANT, "There is nothing in your notes yet.")
                return
            }
            val answer = runCatching { complete(q, history, context, tasks) }
            _messages.value = _messages.value + answer.fold(
                onSuccess = { ChatMessage(ChatMessage.Role.ASSISTANT, it, ChatPrompt.sources(it, context)) },
                onFailure = { ChatMessage(ChatMessage.Role.ASSISTANT, it.message ?: "Something went wrong.", isError = true) },
            )
        } finally {
            _isThinking.value = false
            _status.value = ""
        }
    }

    private suspend fun complete(question: String, history: List<ChatMessage>, context: List<ChatChunk>, tasks: String): String {
        val system = ChatPrompt.system(tasks.isNotEmpty())
        val user = ChatPrompt.user(question, history, context, tasks)
        return when (Prefs.billing) {
            SummaryBilling.LOCAL -> {
                val model = TextModels.selected ?: throw SummaryException("No on-device model is available.")
                model.beginUse()
                try {
                    val installed = model.isInstalled
                    _status.value = if (installed) "Loading model …" else "Downloading model …"
                    model.ensureReady { fraction ->
                        _status.value = if (!installed && fraction < 1) "Downloading model … ${(fraction * 100).toInt()} %" else "Loading model …"
                    }
                    _status.value = "Thinking …"
                    model.generate(system, user, 700)
                } finally {
                    model.endUse()
                }
            }
            SummaryBilling.BYOK -> {
                val provider = AIProvider.current
                val key = provider.apiKey
                if (provider.requiresKey && key.isEmpty()) throw SummaryException.missingAPIKey(provider.label)
                _status.value = "Thinking …"
                CloudLLM.complete(provider, key, provider.model, system, user)
            }
        }
    }
}

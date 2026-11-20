package de.letzgo.porridge.cloud

import de.letzgo.porridge.AppGraph
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.logic.ChatContext
import de.letzgo.porridge.logic.ChatLogic
import de.letzgo.porridge.logic.SummaryException
import de.letzgo.porridge.ml.TextModels
import de.letzgo.porridge.model.ChatEntry
import de.letzgo.porridge.model.ChatSource
import de.letzgo.porridge.model.ChatThread
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer

/**
 * iOS: `ChatService` (Services/ChatService.swift) — fragt die Notizen: liest die Frage als Filter und findet die Einträge
 * und Passagen, die zu ihr passen (`index/NoteIndex.kt`, `logic/ChatDocument.kt`, `logic/ChatLogic.kt`), lässt das in den Einstellungen gewählte Modell daraus antworten und hält
 * Frage und Antwort in ihrem Chat (`ChatThread`, `ChatEntry`).
 */
object ChatService {
    /** Der Chat, der gerade beantwortet wird. */
    private val _thinking = MutableStateFlow<String?>(null)
    val thinking: StateFlow<String?> = _thinking.asStateFlow()
    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status.asStateFlow()

    const val NO_MODEL = "No model is ready for the chat. Download or add one in Settings, under AI."

    private val sourcesJson = ListSerializer(ChatSource.serializer())

    fun sources(entry: ChatEntry): List<ChatSource> =
        entry.sourcesData?.let { runCatching { PorridgeJson.decodeFromString(sourcesJson, it) }.getOrNull() } ?: emptyList()

    suspend fun delete(thread: ChatThread) {
        val chats = PorridgeDatabase.shared.chats()
        chats.deleteEntries(thread.id)
        chats.deleteThread(thread.id)
    }

    suspend fun ask(question: String, thread: ChatThread, notes: List<Note>, folders: List<NoteFolder>) {
        val q = question.trim()
        if (q.isEmpty() || _thinking.value != null) return
        val chats = PorridgeDatabase.shared.chats()
        val history = chats.entries(thread.id).filter { !it.isError }.takeLast(4).map { it.isUser to it.text }
        chats.upsert(thread.copy(title = thread.title.ifEmpty { ChatLogic.title(q) }, updatedAt = System.currentTimeMillis()))
        chats.upsert(ChatEntry(threadID = thread.id, roleRaw = "user", text = q))
        _thinking.value = thread.id
        _status.value = "Searching your notes…"

        suspend fun answer(text: String, sources: List<ChatSource> = emptyList(), isError: Boolean = false) {
            // Der Chat wurde gelöscht, während das Modell arbeitete: Es gibt nichts, wohin geschrieben würde.
            val current = chats.thread(thread.id) ?: return
            chats.upsert(ChatEntry(
                threadID = thread.id, roleRaw = "assistant", text = text, isError = isError,
                sourcesData = sources.takeIf { it.isNotEmpty() }?.let { PorridgeJson.encodeToString(sourcesJson, it) },
            ))
            chats.upsert(current.copy(updatedAt = System.currentTimeMillis()))
        }

        try {
            // Was seit dem letzten Blick hereinkam, wird zuerst in den Index gelesen.
            val index = AppGraph.index
            index.refresh(notes)
            // Die Buckets beim Namen: Eine Frage kann einen nennen, und jeder Eintrag sagt, wo er liegt.
            val names = folders.associate { it.id to it.name }
            val within = thread.projectID?.let { ChatLogic.scope(it, notes).map { note -> note.id }.toSet() }
            val found = index.context(q, within, names)
            if (found.isEmpty && found.matched == null) {
                answer(if (thread.projectID == null) "There is nothing in your notes yet." else "There is nothing in this bucket yet.")
                return
            }
            val result = runCatching { complete(q, history, found, thread.projectID?.let { names[it] }) }
            result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            result.fold(
                onSuccess = { answer(it, ChatLogic.sources(it, found.items)) },
                onFailure = { answer(it.message ?: "Something went wrong.", isError = true) },
            )
        } finally {
            _thinking.value = null
            _status.value = ""
        }
    }

    private suspend fun complete(
        question: String, history: List<Pair<Boolean, String>>, context: ChatContext, bucket: String?,
    ): String {
        val system = ChatLogic.system(bucket)
        val user = ChatLogic.user(question, history, context)
        return when (val chosen = SummaryModel.current) {
            is SummaryModel.Local -> {
                val model = TextModels.selected ?: throw SummaryException(NO_MODEL)
                // Eine Frage beginnt nie von sich aus einen Download von Gigabytes: Das Modell wird in den Einstellungen geholt.
                if (!model.isInstalled) throw SummaryException(NO_MODEL)
                model.beginUse()
                try {
                    _status.value = "Loading model…"
                    model.ensureReady { }
                    _status.value = "Thinking…"
                    model.generate(system, user, 700)
                } finally {
                    model.endUse()
                }
            }
            is SummaryModel.Cloud -> {
                val key = chosen.provider.apiKey
                if (chosen.provider.requiresKey && key.isEmpty()) throw SummaryException.missingAPIKey(chosen.provider.label)
                _status.value = "Thinking…"
                CloudLLM.complete(chosen.provider, key, chosen.modelId, system, user)
            }
        }
    }
}

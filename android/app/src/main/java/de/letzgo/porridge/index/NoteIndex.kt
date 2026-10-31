package de.letzgo.porridge.index

import de.letzgo.porridge.cloud.ChatContextSource
import de.letzgo.porridge.logic.ChatChunk
import de.letzgo.porridge.logic.ChatRetrieval
import de.letzgo.porridge.ml.SentenceEmbedder
import de.letzgo.porridge.model.Note
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.cbor.Cbor
import java.io.File
import java.security.MessageDigest

/**
 * iOS: `NoteIndex` (Services/NoteIndex.swift) — die Passagen aller Notizen für Chat und Suche: Wortstatistik für BM25
 * und ein Satzvektor. In einer eigenen Datei (jederzeit aus den Notizen neu baubar); nur geänderte Notizen werden neu
 * geschnitten und eingebettet.
 */
@OptIn(ExperimentalSerializationApi::class)
class NoteIndex(
    private val file: File,
    private val embedder: () -> SentenceEmbedder?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) : ChatContextSource {
    @Serializable
    internal data class IndexedNote(val hash: String, val chunks: List<ChatChunk>)

    @Serializable
    private data class Stored(val version: Int, val notes: Map<String, IndexedNote>)

    private val lock = Mutex()
    private var entries = HashMap<String, IndexedNote>()
    @Volatile private var flat: List<ChatChunk> = emptyList()
    @Volatile var loaded = false
        private set
    private var saveJob: Job? = null
    private var embedJob: Job? = null

    /** Steigt bei jeder Änderung der Passagen (Suchen laufen neu). */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()
    /** Passagen, die noch auf ihren Vektor warten. */
    private val _pendingEmbeddings = MutableStateFlow(0)
    val pendingEmbeddings: StateFlow<Int> = _pendingEmbeddings.asStateFlow()

    val chunks: List<ChatChunk> get() = flat

    /**
     * Bringt den Index in Einklang mit `notes`: neue und geänderte Notizen werden geschnitten (und im Hintergrund
     * eingebettet), gelöschte fallen weg. Billig, wenn sich nichts geändert hat.
     */
    override suspend fun refresh(notes: List<Note>) {
        lock.withLock {
            if (!loaded) load()
            var changed = false
            val seen = HashSet<String>()
            for (note in notes) {
                if (note.isDeleted) continue
                seen += note.id
                val hash = indexHash(note)
                val old = entries[note.id]
                if (old?.hash == hash) continue
                // Vektoren unveränderter Passagen bleiben.
                val known = old?.chunks?.mapNotNull { c -> c.embedding?.let { c.text to it } }?.toMap().orEmpty()
                entries[note.id] = IndexedNote(hash, ChatRetrieval.chunks(listOf(note)).map { it.copy(embedding = known[it.text]) })
                changed = true
            }
            if (entries.keys.retainAll(seen)) changed = true
            if (changed) {
                rebuildFlat()
                scheduleSave()
            }
        }
        embedMissing()
    }

    private fun rebuildFlat() {
        flat = entries.values.flatMap { it.chunks }
        _version.value += 1
    }

    private fun embedMissing() {
        val missing = flat.filter { it.embedding == null }
        _pendingEmbeddings.value = missing.size
        if (missing.isEmpty() || embedJob?.isActive == true) return
        embedJob = scope.launch {
            val model = embedder()
            if (model == null || !model.isAvailable()) {
                _pendingEmbeddings.value = 0
                return@launch
            }
            val batch = mutableListOf<Triple<String, String, FloatArray>>()
            missing.forEachIndexed { i, chunk ->
                model.vector(chunk.text)?.let { batch += Triple(chunk.noteID, chunk.text, it) }
                if (batch.size >= 20 || i == missing.lastIndex) {
                    store(batch.toList(), remaining = missing.size - i - 1)
                    batch.clear()
                }
            }
            // Während des Laufs können Passagen dazugekommen sein.
            if (flat.any { it.embedding == null }) {
                embedJob = null
                embedMissing()
            }
        }
    }

    private suspend fun store(vectors: List<Triple<String, String, FloatArray>>, remaining: Int) = lock.withLock {
        for ((noteID, text, vector) in vectors) {
            val entry = entries[noteID] ?: continue
            entries[noteID] = entry.copy(chunks = entry.chunks.map { if (it.text == text && it.embedding == null) it.copy(embedding = vector) else it })
        }
        _pendingEmbeddings.value = remaining
        rebuildFlat()
        scheduleSave()
    }

    /** Die passendsten Passagen: nach Wörtern (BM25) und Bedeutung (Vektor) gemischt. */
    override suspend fun search(question: String, budget: Int): List<ChatChunk> {
        val vector = embedder()?.takeIf { it.isAvailable() }?.vector(question)
        return ChatRetrieval.search(question, flat, vector, budget)
    }

    override fun recent(budget: Int): List<ChatChunk> = ChatRetrieval.recent(flat, budget)

    /** Notizen, in denen jedes Wort der Anfrage vorkommt (Wortformen zählen), für die Listensuche. Null, solange nicht geladen. */
    fun noteIDs(query: String): Set<String>? {
        if (!loaded) return null
        val words = ChatRetrieval.tokens(query).toSet()
        val snapshot = HashMap(entries)
        if (words.isEmpty()) return snapshot.keys
        return snapshot.filterValues { entry -> words.all { word -> entry.chunks.any { ChatRetrieval.frequency(word, it) > 0 } } }.keys
    }

    // Datei

    private suspend fun load() {
        loaded = true
        val stored = withContext(Dispatchers.IO) {
            runCatching { Cbor.decodeFromByteArray(Stored.serializer(), file.readBytes()) }.getOrNull()
        }
        if (stored != null && stored.version == FILE_VERSION) {
            entries = HashMap(stored.notes)
            rebuildFlat()
        }
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        val snapshot = Stored(FILE_VERSION, HashMap(entries))
        saveJob = scope.launch(Dispatchers.IO) {
            delay(2000)
            val bytes = Cbor.encodeToByteArray(Stored.serializer(), snapshot)
            file.parentFile?.mkdirs()
            val tmp = File(file.path + ".tmp")
            tmp.writeBytes(bytes)
            tmp.renameTo(file)
        }
    }

    /** Für Tests: wartet, bis Einbetten und Speichern fertig sind. */
    internal suspend fun idle() {
        embedJob?.join()
        saveJob?.join()
    }

    companion object {
        private const val FILE_VERSION = 1

        /** Ändert sich, sobald sich etwas ändert, woraus die Passagen bestehen (SHA-256, stabil über Starts). */
        fun indexHash(note: Note): String {
            val digest = MessageDigest.getInstance("SHA-256")
            for (part in listOf(note.title, note.text, note.summary.orEmpty(), note.pageText.orEmpty(), note.url.orEmpty(), note.labels.joinToString(","), note.createdAt.toString())) {
                digest.update(part.toByteArray())
                digest.update(0)
            }
            note.segmentsData?.let { digest.update(it.toByteArray()) }
            note.speakersData?.let { digest.update(it.toByteArray()) }
            // Links bekamen eine eigene Passage (ihre Adresse): ihre Passagen werden einmal neu geschnitten.
            if (note.url != null) digest.update("link-passage".toByteArray())
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

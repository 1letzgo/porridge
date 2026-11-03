package de.letzgo.porridge.index

import de.letzgo.porridge.logic.NoteChunk
import de.letzgo.porridge.logic.NoteChunks
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
 * iOS: `NoteIndex` (Services/NoteIndex.swift) — die Passagen aller Notizen mit ihrer Wortstatistik, für die Suche. In einer
 * eigenen Datei (jederzeit aus den Notizen neu baubar); nur geänderte Notizen werden neu geschnitten.
 */
@OptIn(ExperimentalSerializationApi::class)
class NoteIndex(
    private val file: File,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    @Serializable
    internal data class IndexedNote(val hash: String, val chunks: List<NoteChunk>)

    @Serializable
    private data class Stored(val version: Int, val notes: Map<String, IndexedNote>)

    private val lock = Mutex()
    private var entries = HashMap<String, IndexedNote>()
    @Volatile var loaded = false
        private set
    private var saveJob: Job? = null

    /** Steigt bei jeder Änderung der Passagen (Suchen laufen neu). */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()

    /**
     * Bringt den Index in Einklang mit `notes`: neue und geänderte Notizen werden geschnitten, gelöschte fallen weg.
     * Billig, wenn sich nichts geändert hat.
     */
    suspend fun refresh(notes: List<Note>) {
        lock.withLock {
            if (!loaded) load()
            var changed = false
            val seen = HashSet<String>()
            for (note in notes) {
                if (note.isDeleted) continue
                seen += note.id
                val hash = indexHash(note)
                if (entries[note.id]?.hash == hash) continue
                entries[note.id] = IndexedNote(hash, NoteChunks.chunks(listOf(note)))
                changed = true
            }
            if (entries.keys.retainAll(seen)) changed = true
            if (changed) {
                _version.value += 1
                scheduleSave()
            }
        }
    }

    /** Notizen, in denen jedes Wort der Anfrage vorkommt (Wortformen zählen), für die Listensuche. Null, solange nicht geladen. */
    fun noteIDs(query: String): Set<String>? {
        if (!loaded) return null
        val words = NoteChunks.tokens(query).toSet()
        val snapshot = HashMap(entries)
        if (words.isEmpty()) return snapshot.keys
        return snapshot.filterValues { entry -> words.all { word -> entry.chunks.any { NoteChunks.frequency(word, it) > 0 } } }.keys
    }

    // Datei

    private suspend fun load() {
        loaded = true
        val stored = withContext(Dispatchers.IO) {
            runCatching { Cbor.decodeFromByteArray(Stored.serializer(), file.readBytes()) }.getOrNull()
        }
        if (stored != null && stored.version == FILE_VERSION) {
            entries = HashMap(stored.notes)
            _version.value += 1
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

    /** Für Tests: wartet, bis das Speichern fertig ist. */
    internal suspend fun idle() {
        saveJob?.join()
    }

    companion object {
        private const val FILE_VERSION = 2

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

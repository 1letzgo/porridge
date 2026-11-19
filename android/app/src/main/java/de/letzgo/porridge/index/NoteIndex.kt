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
    /** Wird nie verändert, nur ersetzt: Die Suche liest von einem anderen Thread, während [refresh] rechnet. */
    @Volatile private var entries: Map<String, IndexedNote> = emptyMap()
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
    suspend fun refresh(notes: List<Note>) = withContext(Dispatchers.Default) {
        // Nicht auf dem Thread der Oberfläche: Jede Notiz wird gehasht, bei vielen Notizen ruckelte sonst die Liste.
        lock.withLock {
            if (!loaded) load()
            var changed = false
            val next = HashMap(entries)
            val seen = HashSet<String>()
            for (note in notes) {
                if (note.isDeleted) continue
                seen += note.id
                val hash = indexHash(note)
                if (next[note.id]?.hash == hash) continue
                next[note.id] = IndexedNote(hash, NoteChunks.chunks(listOf(note)))
                changed = true
            }
            if (next.keys.retainAll(seen)) changed = true
            if (changed) {
                entries = next
                _version.value += 1
                scheduleSave()
            }
        }
    }

    /** Alle Passagen, für den Chat (`logic/ChatLogic.kt`). */
    fun chunks(): List<NoteChunk> = entries.values.flatMap { it.chunks }

    /** Notizen, in denen jedes Wort der Anfrage vorkommt (Wortformen zählen), für die Listensuche. Null, solange nicht geladen. */
    fun noteIDs(query: String): Set<String>? {
        if (!loaded) return null
        val words = NoteChunks.tokens(query).toSet()
        val snapshot = entries
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
        } else {
            // Unlesbar oder ein altes Format: ein reiner Cache, er wird aus den Notizen neu gebaut.
            withContext(Dispatchers.IO) { file.delete() }
        }
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        val snapshot = Stored(FILE_VERSION, HashMap(entries))
        saveJob = scope.launch(Dispatchers.IO) {
            delay(2000)
            // Ein reiner Cache: Kein Platz auf dem Gerät ist kein Grund abzustürzen; er wird beim nächsten Start neu gebaut.
            val tmp = File(file.path + ".tmp")
            try {
                val bytes = Cbor.encodeToByteArray(Stored.serializer(), snapshot)
                file.parentFile?.mkdirs()
                tmp.writeBytes(bytes)
                tmp.renameTo(file)
            } catch (e: Exception) {
                tmp.delete()
                de.letzgo.porridge.data.CrashLog.note("Search index not saved", e)
            }
        }
    }

    /** Für Tests: wartet, bis das Speichern fertig ist. */
    internal suspend fun idle() {
        saveJob?.join()
    }

    companion object {
        private const val FILE_VERSION = 3

        /** Ändert sich, sobald sich etwas ändert, woraus die Passagen bestehen (SHA-256, stabil über Starts). */
        fun indexHash(note: Note): String {
            val digest = MessageDigest.getInstance("SHA-256")
            for (part in listOf(note.title, note.text, note.summary.orEmpty(), note.pageText.orEmpty(), note.url.orEmpty(), note.labels.joinToString(","), note.createdAt.toString())) {
                digest.update(part.toByteArray())
                digest.update(0)
            }
            note.segmentsData?.let { digest.update(it.toByteArray()) }
            note.speakersData?.let { digest.update(it.toByteArray()) }
            // Die Namen ihrer Dateien sind auch eine Passage.
            note.attachmentsData?.let { digest.update(it.toByteArray()) }
            // Links bekamen eine eigene Passage (ihre Adresse): ihre Passagen werden einmal neu geschnitten.
            if (note.url != null) digest.update("link-passage".toByteArray())
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

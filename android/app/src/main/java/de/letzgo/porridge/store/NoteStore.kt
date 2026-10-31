package de.letzgo.porridge.store

import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import java.util.concurrent.TimeUnit

/** iOS: `NoteStore` — Papierkorb, Wiederherstellen, endgültiges Löschen und Ordnerpflege. */
class NoteStore(private val db: PorridgeDatabase = PorridgeDatabase.shared) {
    companion object {
        /** Tage, die eine Notiz in „Recently Deleted“ bleibt. */
        const val TRASH_DAYS = 30
    }

    suspend fun save(note: Note) = db.notes().upsert(note.copy(updatedAt = System.currentTimeMillis()))

    suspend fun trash(note: Note) = db.notes().upsert(note.copy(deletedAt = System.currentTimeMillis(), isPinned = false))

    suspend fun restore(note: Note) {
        val folderGone = note.folderID != null && db.folders().count(note.folderID) == 0
        db.notes().upsert(note.copy(deletedAt = null, folderID = if (folderGone) null else note.folderID))
    }

    suspend fun deletePermanently(note: Note) {
        note.audioFileNames.forEach(AudioStore::delete)
        AudioStore.delete(note.pendingAudioFileName)
        AudioStore.delete(note.audioFileName)
        ActionItemStore(db).remove(note.id)
        db.notes().delete(note)
    }

    /** Löscht Notizen, die länger als [TRASH_DAYS] im Papierkorb liegen. */
    suspend fun purgeExpired(now: Long = System.currentTimeMillis()) {
        val limit = now - TimeUnit.DAYS.toMillis(TRASH_DAYS.toLong())
        db.notes().trashed().filter { (it.deletedAt ?: Long.MAX_VALUE) < limit }.forEach { deletePermanently(it) }
    }

    /** Löscht ein Projekt (früher Ordner); seine Notizen bleiben (siehe [Projects.delete]). */
    suspend fun delete(folder: NoteFolder) = Projects.delete(folder)
}

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

    suspend fun trash(note: Note) {
        val now = System.currentTimeMillis()
        db.notes().upsert(note.copy(deletedAt = now, isPinned = false, updatedAt = now))
    }

    suspend fun restore(note: Note) {
        val folderGone = note.folderID != null && db.folders().count(note.folderID) == 0
        db.notes().upsert(note.copy(deletedAt = null, folderID = if (folderGone) null else note.folderID, updatedAt = System.currentTimeMillis()))
    }

    /** Archiviert die Notiz, auf dem frischen Stand der Datenbank. */
    suspend fun archive(note: Note) = setArchived(note, System.currentTimeMillis())

    suspend fun unarchive(note: Note) = setArchived(note, null)

    private suspend fun setArchived(note: Note, archivedAt: Long?) {
        val current = db.notes().get(note.id) ?: return
        db.notes().upsert(current.copy(archivedAt = archivedAt, updatedAt = System.currentTimeMillis()))
    }

    suspend fun deletePermanently(note: Note) {
        note.audioFileNames.forEach(AudioStore::delete)
        AudioStore.delete(note.pendingAudioFileName)
        AudioStore.delete(note.audioFileName)
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

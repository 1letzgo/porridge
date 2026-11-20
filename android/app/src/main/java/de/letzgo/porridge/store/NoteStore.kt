package de.letzgo.porridge.store

import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.logic.Todos
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.TodoState
import java.util.concurrent.TimeUnit

/** iOS: `NoteStore` — Papierkorb, Wiederherstellen, endgültiges Löschen und Ordnerpflege. */
class NoteStore(private val db: PorridgeDatabase = PorridgeDatabase.shared) {
    companion object {
        /** Tage, die eine Notiz in „Recently Deleted“ bleibt. */
        const val TRASH_DAYS = 30
    }

    suspend fun save(note: Note) = db.notes().upsert(note.copy(updatedAt = System.currentTimeMillis()))

    /**
     * Ändert eine Notiz auf dem frischen Stand der Datenbank. Wer eine Zeile aus der Oberfläche zurückschreibt, überschreibt,
     * was inzwischen dazukam (ein fertiges Transkript, eine Zusammenfassung). [touch] setzt `updatedAt`, damit die Änderung
     * im Abgleich gegen das andere Gerät zählt; Anheften lässt es wie auf iOS stehen.
     */
    suspend fun update(id: String, touch: Boolean = true, change: (Note) -> Note): Note? {
        val current = db.notes().get(id) ?: return null
        val changed = change(current)
        val updated = if (touch) changed.copy(updatedAt = System.currentTimeMillis()) else changed
        db.notes().upsert(updated)
        return updated
    }

    suspend fun trash(note: Note) {
        val now = System.currentTimeMillis()
        update(note.id) { it.copy(deletedAt = now, isPinned = false) }
    }

    suspend fun restore(note: Note) {
        val folderGone = note.folderID != null && db.folders().count(note.folderID) == 0
        update(note.id) { it.copy(deletedAt = null, folderID = if (folderGone) null else it.folderID) }
    }

    /** Archiviert die Notiz, auf dem frischen Stand der Datenbank. */
    suspend fun archive(note: Note) = setArchived(note, System.currentTimeMillis())

    suspend fun unarchive(note: Note) = setArchived(note, null)

    private suspend fun setArchived(note: Note, archivedAt: Long?) {
        // iOS: `Archive.set` — im Archiv ist nichts angeheftet. Ein To-do, das an einem früheren Tag erledigt wurde, ist von
        // selbst aus den Listen: aus dem Archiv geholt, ist es wieder offen.
        update(note.id) {
            val reopened = if (archivedAt == null && it.isPutAway) it.copy(todoStateRaw = TodoState.OPEN.raw, todoDoneAt = null) else it
            reopened.copy(archivedAt = archivedAt, isPinned = if (archivedAt != null) false else it.isPinned)
        }
    }

    // To-dos (iOS: `Todos.setTodo`, `setDone`, `toggleSubtask`, `create(fromTask:)`), auf dem frischen Stand der Datenbank

    /** Macht aus einer Notiz ein To-do oder wieder eine Notiz; der Text bleibt. */
    suspend fun setTodo(note: Note, isTodo: Boolean) = update(note.id) { Todos.withTodo(it, isTodo) ?: it }

    /** Hakt das To-do ab (mit allen Unteraufgaben) oder öffnet es wieder. */
    suspend fun setDone(note: Note, done: Boolean) = update(note.id) { Todos.withDone(it, done) ?: it }

    /** Setzt den fälligen Tag ("yyyy-MM-dd") oder nimmt ihn weg (null, dann "none"). */
    suspend fun setDue(note: Note, key: String?) = update(note.id) { Todos.withDue(it, key) ?: it }

    /** Hakt eine Unteraufgabe ab oder ab; das To-do folgt. */
    suspend fun toggleSubtask(note: Note, line: Int) = update(note.id) { Todos.withToggledSubtask(it, line) }

    /** Eine Aufgabenzeile der Zusammenfassung als eigenes To-do; nie aus einem Link oder einer Datei. */
    suspend fun makeTodo(task: String, source: Note): Note? {
        val todo = Todos.fromTask(task, source) ?: return null
        db.notes().upsert(todo)
        return todo
    }

    /** iOS: `Inbox.file` — legt die Notiz in einen Bucket; sie verlässt den Eingang. */
    suspend fun file(note: Note, project: String) = update(note.id) { de.letzgo.porridge.logic.InboxLogic.filed(it, project) }

    suspend fun dismissSuggestions(note: Note) = update(note.id) { it.copy(suggestedProjectIDs = emptyList()) }

    suspend fun deletePermanently(note: Note) {
        note.storedFileNames.forEach(AudioStore::delete)
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

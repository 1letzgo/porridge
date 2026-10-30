package de.letzgo.porridge.store

import de.letzgo.porridge.logic.ActionItemsLogic
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note

/** iOS: Speicher-Teil von `ActionItems` — hält die Einträge einer Notiz im Einklang mit ihrer Zusammenfassung. */
class ActionItemStore(private val db: PorridgeDatabase = PorridgeDatabase.shared) {
    suspend fun sync(note: Note) {
        val plan = ActionItemsLogic.sync(note, db.actionItems().forNote(note.id))
        if (plan.isEmpty) return
        db.actionItems().upsertAll(plan.upserts)
        plan.deletes.forEach { db.actionItems().delete(it) }
    }

    /**
     * Bringt beim Start die Einträge jeder Notiz in Einklang mit ihrer Zusammenfassung: alte Notizen bekommen
     * ihre, Seiten verlieren ihre. Schreibt nichts, wenn sich nichts ändert.
     */
    suspend fun backfill(notes: List<Note>) {
        for (note in notes) if (!note.isDeleted && (note.isLink || !note.summary.isNullOrEmpty())) sync(note)
    }

    /** Legt eine von Hand getippte Aufgabe an und gibt sie zurück, bereit zum Ausfüllen. */
    suspend fun newTask(): ActionItem = ActionItem(source = "manual").also { db.actionItems().upsert(it) }

    suspend fun delete(item: ActionItem) = db.actionItems().delete(item)

    suspend fun save(item: ActionItem) = db.actionItems().upsert(item.copy(updatedAt = System.currentTimeMillis()))

    /** Eine von Hand angelegte Aufgabe ohne Titel und Text wird nicht behalten. */
    suspend fun dropEmptyManual() {
        db.actionItems().all().filter { it.source == "manual" && it.text.isBlank() && it.details.isBlank() }.forEach { db.actionItems().delete(it) }
    }

    /** Die Notiz (oder ihre Zusammenfassung) geht: unberührte Aufgaben gehen mit, die anderen bleiben eigenständig. */
    suspend fun remove(noteID: String) {
        for (item in db.actionItems().forNote(noteID)) {
            if (ActionItemsLogic.isUntouched(item)) db.actionItems().delete(item)
            else db.actionItems().upsert(item.copy(noteID = null, source = "kept"))
        }
    }

    /** Hakt einen Eintrag ab (oder nicht) und seine Zeile in der Zusammenfassung mit. */
    suspend fun setDone(item: ActionItem, done: Boolean) {
        val now = System.currentTimeMillis()
        db.actionItems().upsert(item.copy(isDone = done, doneAt = if (done) now else null, updatedAt = now))
        val note = item.noteID?.let { db.notes().get(it) } ?: return
        val summary = note.summary ?: return
        val updated = ActionItemsLogic.summaryAfterSetDone(summary, item, done, db.actionItems().forNote(note.id))
        if (updated != summary) db.notes().upsert(note.copy(summary = updated))
    }
}

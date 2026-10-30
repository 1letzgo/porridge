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

    /** Gibt jeder Notiz mit Zusammenfassung ihre Einträge (für Notizen von vor den Einträgen). */
    suspend fun backfill(notes: List<Note>) {
        for (note in notes) if (!note.isDeleted && !note.summary.isNullOrEmpty() && db.actionItems().forNote(note.id).isEmpty()) sync(note)
    }

    /** Hakt einen Eintrag ab (oder nicht) und seine Zeile in der Zusammenfassung mit. */
    suspend fun setDone(item: ActionItem, done: Boolean) {
        db.actionItems().upsert(item.copy(isDone = done, doneAt = if (done) System.currentTimeMillis() else null))
        val note = item.noteID?.let { db.notes().get(it) } ?: return
        val summary = note.summary ?: return
        val updated = ActionItemsLogic.summaryAfterSetDone(summary, item, done, db.actionItems().forNote(note.id))
        if (updated != summary) db.notes().upsert(note.copy(summary = updated))
    }
}

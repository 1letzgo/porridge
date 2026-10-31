package de.letzgo.porridge.data

import de.letzgo.porridge.logic.ProjectsLogic
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.store.PorridgeDatabase

/** iOS: `Projects` — Projekte anlegen, umbenennen, löschen und zuordnen. Ein Projekt ist ein `NoteFolder`. */
object Projects {
    private val db get() = PorridgeDatabase.shared

    suspend fun create(name: String): NoteFolder {
        val now = System.currentTimeMillis()
        return NoteFolder(name = name.trim(), createdAt = now, updatedAt = now).also { db.folders().upsert(it) }
    }

    suspend fun rename(project: NoteFolder, name: String) =
        db.folders().upsert(project.copy(name = name.trim(), updatedAt = System.currentTimeMillis()))

    /** Löscht nur das Projekt; seine Notizen und Aufgaben bleiben und verlieren die Zuordnung. */
    suspend fun delete(project: NoteFolder) {
        val (notes, items) = ProjectsLogic.removing(project.id, db.notes().all(), db.actionItems().all(), System.currentTimeMillis())
        db.notes().upsertAll(notes)
        db.actionItems().upsertAll(items)
        db.folders().deleteAll(listOf(project.id))
    }

    /** Ordnet die Notiz dem Projekt zu oder nimmt sie heraus (auf dem frischen Stand der Datenbank). */
    suspend fun toggle(note: Note, projectID: String) {
        val current = db.notes().get(note.id) ?: note
        db.notes().upsert(current.copy(projectIDs = ProjectsLogic.toggled(current.projectIDs, projectID), updatedAt = System.currentTimeMillis()))
    }

    suspend fun toggle(item: ActionItem, projectID: String) {
        val current = db.actionItems().get(item.id) ?: item
        db.actionItems().upsert(current.copy(projectIDs = ProjectsLogic.toggled(current.projectIDs, projectID), updatedAt = System.currentTimeMillis()))
    }

    /** Einmalig beim Start: Notizen in Ordnern gehören danach zum gleichnamigen Projekt. */
    suspend fun migrateFolders() {
        val changed = ProjectsLogic.migrateFolders(db.notes().all(), System.currentTimeMillis())
        if (changed.isNotEmpty()) db.notes().upsertAll(changed)
    }
}

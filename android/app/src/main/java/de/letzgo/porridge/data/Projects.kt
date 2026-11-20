package de.letzgo.porridge.data

import de.letzgo.porridge.logic.ProjectsLogic
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

    /** Archiviert nur das Projekt; seine Notizen bleiben unverändert darin. */
    suspend fun archive(project: NoteFolder) {
        val now = System.currentTimeMillis()
        db.folders().upsert(project.copy(archivedAt = now, isPinned = false, updatedAt = now))
    }

    suspend fun unarchive(project: NoteFolder) =
        db.folders().upsert(project.copy(archivedAt = null, updatedAt = System.currentTimeMillis()))

    suspend fun togglePin(project: NoteFolder) =
        db.folders().upsert(project.copy(isPinned = !project.isPinned, updatedAt = System.currentTimeMillis()))

    /** Löscht nur das Projekt; seine Notizen bleiben und verlieren die Zuordnung. */
    suspend fun delete(project: NoteFolder) {
        db.notes().upsertAll(ProjectsLogic.removing(project.id, db.notes().all(), System.currentTimeMillis()))
        db.folders().deleteAll(listOf(project.id))
    }

    /**
     * iOS: `Projects.pruneUnknown` — nimmt die Notizen aus Buckets, die nicht in [known] sind (auf einem anderen Gerät
     * gelöscht, [delete] lief hier also nie): Sonst stünde so eine Notiz in keiner Liste, weder im Eingang noch in einem
     * Bucket. Vorschläge solcher Buckets gehen auch. [known] muss jeden Bucket enthalten, also erst nach dem Abgleich der
     * Buckets eines Sync-Laufs genommen werden. `updatedAt` bleibt: Einen Bucket zu verlassen, den es nicht mehr gibt, ist
     * keine Bearbeitung und darf die Notiz anderswo nicht neuer machen.
     * @return die geänderten Notizen (nur sie).
     */
    fun pruneUnknown(notes: List<Note>, known: Set<String>): List<Note> {
        val ids = known.map { it.uppercase() }.toSet()
        return notes.mapNotNull { note ->
            val projects = note.projectIDs.filter { it.uppercase() in ids }
            val suggested = note.suggestedProjectIDs.filter { it.uppercase() in ids }
            if (projects.size == note.projectIDs.size && suggested.size == note.suggestedProjectIDs.size) null
            else note.copy(projectIDs = projects, suggestedProjectIDs = suggested)
        }
    }

    /** Ordnet die Notiz dem Projekt zu oder nimmt sie heraus (auf dem frischen Stand der Datenbank). */
    suspend fun toggle(note: Note, projectID: String) {
        val current = db.notes().get(note.id) ?: note
        val ids = ProjectsLogic.toggled(current.projectIDs, projectID)
        // Von Hand in einen Bucket gelegt: aus dem Eingang, was auch immer vorgeschlagen war.
        val filed = if (projectID in ids) current.copy(filedAt = current.filedAt ?: System.currentTimeMillis(), suggestedProjectIDs = emptyList()) else current
        db.notes().upsert(filed.copy(projectIDs = ids, updatedAt = System.currentTimeMillis()))
    }


    /** Einmalig beim Start: Notizen in Ordnern gehören danach zum gleichnamigen Projekt. */
    suspend fun migrateFolders() {
        val changed = ProjectsLogic.migrateFolders(db.notes().all(), System.currentTimeMillis())
        if (changed.isNotEmpty()) db.notes().upsertAll(changed)
    }
}

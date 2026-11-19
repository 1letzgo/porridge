package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder

/**
 * iOS: `HomeList` — was die Startseite von den Buckets zeigt, was im Archiv liegt und was die Suche findet.
 */
object HomeListLogic {
    fun activeProjects(folders: List<NoteFolder>): List<NoteFolder> = folders.filter { it.archivedAt == null }

    fun archivedProjects(folders: List<NoteFolder>): List<NoteFolder> = folders.filter { it.archivedAt != null }

    /** So viele nicht angeheftete Projekte zeigt die Liste vor „More“. */
    const val RECENT_PROJECTS = 5

    /** [hidden]: so viele nicht angeheftete Projekte lässt die Liste weg, solange nicht alle gezeigt werden. */
    data class ShownProjects(val shown: List<NoteFolder>, val hidden: Int)

    /** iOS: `shownProjects` — alle angehefteten, dann die zuletzt geänderten übrigen, bis [RECENT_PROJECTS] oder alle. */
    fun shownProjects(projects: List<NoteFolder>, showAll: Boolean, lastChange: (NoteFolder) -> Long): ShownProjects {
        val latest = projects.map { it to lastChange(it) }
            .sortedWith(compareByDescending<Pair<NoteFolder, Long>> { it.second }.thenBy { it.first.name.lowercase() })
            .map { it.first }
        val (pinned, others) = latest.partition { it.isPinned }
        return ShownProjects(pinned + (if (showAll) others else others.take(RECENT_PROJECTS)), maxOf(0, others.size - RECENT_PROJECTS))
    }

    /** Archivierte Notizen; im Papierkorb gelten sie als gelöscht und kommen beim Wiederherstellen zurück. */
    fun archivedNotes(notes: List<Note>): List<Note> =
        notes.filter { !it.isDeleted && it.isArchived }.sortedByDescending { it.updatedAt }

    /** Die Anzahl in der Zeile „Archive“: was die Seite zeigt. */
    fun archiveCount(folders: List<NoteFolder>, notes: List<Note>): Int =
        archivedProjects(folders).size + archivedNotes(notes).size

    /**
     * Treffer unter den Notizen, auch archivierte. [indexIDs]: die Treffer des Suchindex; solange er nicht bereit ist
     * (null), wird der Text selbst durchsucht.
     */
    fun searchNotes(notes: List<Note>, query: String, tags: List<String>, kind: ProjectsLogic.Kind?, indexIDs: Set<String>?): List<Note> {
        return notes.filter { note ->
            !note.isDeleted && matchesKind(note, kind) && hasTags(note, tags) && when {
                query.isBlank() -> true
                indexIDs != null -> note.id in indexIDs || note.title.contains(query, true) || note.url?.contains(query, true) == true
                else -> note.matches(query)
            }
        }.sortedByDescending { it.updatedAt }
    }

    /** iOS: `SearchKind.matches` — „Open To-dos“ findet nur offene, nicht weggeräumte To-dos. */
    fun matchesKind(note: Note, kind: ProjectsLogic.Kind?): Boolean = when (kind) {
        null -> true
        ProjectsLogic.Kind.TODO -> note.isTodo && !note.isDone && !note.isArchived
        else -> ProjectsLogic.kind(note) == kind
    }

    private fun hasTags(note: Note, tags: List<String>) = tags.all { t -> note.tags.any { it.lowercase() == t } }
}

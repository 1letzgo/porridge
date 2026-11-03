package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder

/**
 * iOS: `HomeList` — was in die lange Liste, ins Archiv und in die Suche gehört. In der Liste steht nur, was weder
 * gelöscht noch archiviert ist und in keinem Projekt liegt.
 */
object HomeListLogic {
    /**
     * iOS: `HomeFilter` — worauf der Knopf neben der Suche die lange Liste einengt. Er engt nur ein, was die Liste zeigt:
     * was in einem Projekt liegt, bleibt dort.
     */
    enum class HomeFilter(val title: String, private val kind: ProjectsLogic.Kind? = null) {
        ALL("All"), PROJECTS("Projects"),
        MEETINGS("Meetings", ProjectsLogic.Kind.MEETING), NOTES("Notes", ProjectsLogic.Kind.NOTE), LINKS("Links", ProjectsLogic.Kind.LINK);

        val showsProjects get() = this == ALL || this == PROJECTS

        fun matches(note: Note) = this == ALL || (kind != null && ProjectsLogic.kind(note) == kind)
    }

    /** Nur IDs von Projekten, die es noch gibt, zählen: verwaiste IDs aus dem Sync verstecken nichts. */
    private fun existing(folders: List<NoteFolder>): Set<String> = folders.mapTo(HashSet()) { it.id }

    private fun inProject(note: Note, projects: Set<String>) = note.projectIDs.any { it in projects }

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

    /** So viele Elemente (Angeheftetes, Notizen) zeigt die Liste vor „More“. */
    const val MAX_ELEMENTS = 25

    /** [hidden]: so viele Elemente lässt die Liste weg, solange nicht alle gezeigt werden. */
    data class ElementLimits(val pinned: Int, val notes: Int, val hidden: Int)

    /** iOS: `elementLimits` — teilt [MAX_ELEMENTS] von oben nach unten auf, außer alle werden gezeigt. */
    fun elementLimits(pinned: Int, notes: Int, showAll: Boolean): ElementLimits {
        val total = pinned + notes
        val budget = if (showAll) total else MAX_ELEMENTS
        val shownPinned = minOf(pinned, budget)
        return ElementLimits(shownPinned, minOf(notes, budget - shownPinned), maxOf(0, total - MAX_ELEMENTS))
    }

    /** Meetings, Notizen und Links der Startseite, neueste zuerst. */
    fun homeNotes(notes: List<Note>, folders: List<NoteFolder>): List<Note> {
        val projects = existing(folders)
        return notes.filter { !it.isDeleted && it.archivedAt == null && !inProject(it, projects) }.sortedByDescending { it.updatedAt }
    }

    /** Archivierte Notizen; im Papierkorb gelten sie als gelöscht und kommen beim Wiederherstellen zurück. */
    fun archivedNotes(notes: List<Note>): List<Note> =
        notes.filter { !it.isDeleted && it.archivedAt != null }.sortedByDescending { it.updatedAt }

    /** Die Anzahl in der Zeile „Archive“: was die Seite zeigt. */
    fun archiveCount(folders: List<NoteFolder>, notes: List<Note>): Int =
        archivedProjects(folders).size + archivedNotes(notes).size

    /**
     * Treffer unter den Notizen, auch archivierte. [indexIDs]: die Treffer des Suchindex; solange er nicht bereit ist
     * (null), wird der Text selbst durchsucht.
     */
    fun searchNotes(notes: List<Note>, query: String, tags: List<String>, kind: ProjectsLogic.Kind?, indexIDs: Set<String>?): List<Note> {
        return notes.filter { note ->
            !note.isDeleted && (kind == null || ProjectsLogic.kind(note) == kind) && hasTags(note, tags) && when {
                query.isBlank() -> true
                indexIDs != null -> note.id in indexIDs || note.title.contains(query, true) || note.url?.contains(query, true) == true
                else -> note.matches(query)
            }
        }.sortedByDescending { it.updatedAt }
    }

    private fun hasTags(note: Note, tags: List<String>) = tags.all { t -> note.tags.any { it.lowercase() == t } }
}

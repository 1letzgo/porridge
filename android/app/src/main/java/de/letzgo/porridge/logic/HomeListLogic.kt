package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder

/**
 * iOS: `HomeList` — was in die lange Liste, ins Archiv und in die Suche gehört. In der Liste steht nur, was weder
 * gelöscht noch archiviert ist und in keinem Projekt liegt; eine Aufgabe liegt auch über ihre Notiz in einem Projekt.
 */
object HomeListLogic {
    /** Die Abschnitte der Aufgaben, jeweils mit ihrer Notiz. */
    data class TaskSections(
        val new: List<Pair<ActionItem, Note?>>,
        val mine: List<Pair<ActionItem, Note?>>,
        val general: List<Pair<ActionItem, Note?>>,
        val done: List<Pair<ActionItem, Note?>>,
    )

    /** Nur IDs von Projekten, die es noch gibt, zählen: verwaiste IDs aus dem Sync verstecken nichts. */
    private fun existing(folders: List<NoteFolder>): Set<String> = folders.mapTo(HashSet()) { it.id }

    private fun inProject(note: Note, projects: Set<String>) = note.projectIDs.any { it in projects }

    private fun inProject(item: ActionItem, note: Note?, projects: Set<String>) =
        item.projectIDs.any { it in projects } || (note != null && inProject(note, projects))

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

    /** Meetings, Notizen und Links der Startseite, neueste zuerst. */
    fun homeNotes(notes: List<Note>, folders: List<NoteFolder>): List<Note> {
        val projects = existing(folders)
        return notes.filter { !it.isDeleted && it.archivedAt == null && !inProject(it, projects) }.sortedByDescending { it.updatedAt }
    }

    /**
     * Alle Aufgaben, die irgendwo stehen können, neueste Notiz zuerst. Eine Aufgabe, deren Notiz weg ist, bleibt
     * eigenständig; verworfene, die gelöschter Notizen und solche aus Links fehlen.
     */
    fun tasks(items: List<ActionItem>, notes: List<Note>): List<Pair<ActionItem, Note?>> {
        val byID = notes.associateBy { it.id }
        return items.mapNotNull { item ->
            if (item.kind != ActionItem.Kind.TASK || item.review == ActionItem.Review.DISMISSED) return@mapNotNull null
            val note = item.noteID?.let { byID[it] } ?: return@mapNotNull Triple(item, null, item.createdAt)
            if (note.isDeleted || note.isLink) null else Triple(item, note, note.createdAt)
        }.sortedWith(compareByDescending<Triple<ActionItem, Note?, Long>> { it.third }.thenBy { it.first.order }).map { it.first to it.second }
    }

    /** Die Aufgaben der Startseite. Das Archivieren einer Notiz berührt ihre Aufgaben nicht. */
    fun homeTasks(items: List<ActionItem>, notes: List<Note>, folders: List<NoteFolder>): List<Pair<ActionItem, Note?>> {
        val projects = existing(folders)
        return tasks(items, notes).filter { (item, note) -> item.archivedAt == null && !inProject(item, note, projects) }
    }

    /** New, Mine, General und Done (iOS: `TasksPane`). */
    fun sections(tasks: List<Pair<ActionItem, Note?>>, names: List<String>): TaskSections {
        val (mine, general) = tasks.filter { !it.first.isDone && !it.first.needsReview }.partition { ActionItemsLogic.isMine(it.first, it.second, names) }
        return TaskSections(tasks.filter { it.first.needsReview }, mine, general, tasks.filter { it.first.isDone })
    }

    /** Archivierte Notizen; im Papierkorb gelten sie als gelöscht und kommen beim Wiederherstellen zurück. */
    fun archivedNotes(notes: List<Note>): List<Note> =
        notes.filter { !it.isDeleted && it.archivedAt != null }.sortedByDescending { it.updatedAt }

    fun archivedTasks(items: List<ActionItem>, notes: List<Note>): List<Pair<ActionItem, Note?>> =
        tasks(items, notes).filter { it.first.archivedAt != null }

    /** Die Anzahl in der Zeile „Archive“: was die Seite zeigt. */
    fun archiveCount(folders: List<NoteFolder>, notes: List<Note>, items: List<ActionItem>): Int =
        archivedProjects(folders).size + archivedNotes(notes).size + archivedTasks(items, notes).size

    /**
     * Treffer unter den Notizen, auch archivierte. [indexIDs]: die Treffer des Suchindex; solange er nicht bereit ist
     * (null), wird der Text selbst durchsucht.
     */
    fun searchNotes(notes: List<Note>, query: String, tags: List<String>, kind: ProjectsLogic.Kind?, indexIDs: Set<String>?): List<Note> {
        if (kind == ProjectsLogic.Kind.TASK) return emptyList()
        return notes.filter { note ->
            !note.isDeleted && (kind == null || ProjectsLogic.kind(note) == kind) && hasTags(note, tags) && when {
                query.isBlank() -> true
                indexIDs != null -> note.id in indexIDs || note.title.contains(query, true) || note.url?.contains(query, true) == true
                else -> note.matches(query)
            }
        }.sortedByDescending { it.updatedAt }
    }

    /** Treffer unter den Aufgaben, auch archivierte. Tags kommen von ihrer Notiz. */
    fun searchTasks(items: List<ActionItem>, notes: List<Note>, query: String, tags: List<String>, kind: ProjectsLogic.Kind?): List<Pair<ActionItem, Note?>> {
        if (kind != null && kind != ProjectsLogic.Kind.TASK) return emptyList()
        return tasks(items, notes).filter { (item, note) ->
            (tags.isEmpty() || (note != null && hasTags(note, tags))) && matches(item, query)
        }
    }

    /** Wie `Note.matches`: jedes Wort kommt irgendwo vor (Groß/klein egal). */
    fun matches(item: ActionItem, query: String): Boolean =
        query.trim().split(" ").filter { it.isNotEmpty() }.all { word ->
            item.text.contains(word, true) || item.details.contains(word, true) || item.owner?.contains(word, true) == true
        }

    private fun hasTags(note: Note, tags: List<String>) = tags.all { t -> note.tags.any { it.lowercase() == t } }
}

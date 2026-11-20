package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder

/** iOS: `ProjectsLogic` — wer zu einem Projekt gehört: Notizen, Meetings und Links über ihre `projectIDs`. */
object ProjectsLogic {
    /** [searchTitle]: der Chip der Suche; bei To-dos findet er nur offene (iOS: `SearchKind.todos`, „Open To-dos“). */
    enum class Kind(val title: String, val searchTitle: String = title) {
        TODO("To-dos", "Open To-dos"), MEETING("Meetings"), NOTE("Notes"), LINK("Links"), IMAGE("Images"), FILE("Files"),
    }

    fun kind(note: Note): Kind = when {
        note.isTodo -> Kind.TODO
        note.isLink -> Kind.LINK
        note.isImage -> Kind.IMAGE
        note.isFile -> Kind.FILE
        note.isRecording -> Kind.MEETING
        else -> Kind.NOTE
    }

    /** Alles eines Projekts, neueste zuerst; Gelöschtes und Archiviertes fehlen. */
    fun elements(projectID: String, notes: List<Note>): List<Note> =
        notes.filter { !it.isDeleted && !it.isArchived && projectID in it.projectIDs }.sortedByDescending { it.updatedAt }

    /**
     * iOS: `ProjectContent` — die Liste eines Buckets, flach und ohne Abschnitte. [filter] null („All“): alle Arten
     * gemischt, neueste Änderung zuerst (erledigte To-dos ordnen sich normal ein). Chip „To-dos“: nach fälligem Tag
     * ([Todos.byDue]). Andere Chips: neueste Änderung zuerst. Überall stehen angeheftete Notizen oben, unter sich
     * genauso sortiert.
     */
    fun ordered(elements: List<Note>, filter: Kind? = null): List<Note> {
        val shown = elements.filter { filter == null || kind(it) == filter }
        fun sort(group: List<Note>) = if (filter == Kind.TODO) Todos.byDue(group.sortedByDescending { it.updatedAt }) else group.sortedByDescending { it.updatedAt }
        val (pinned, rest) = shown.partition { it.isPinned }
        return sort(pinned) + sort(rest)
    }

    /** Offene To-dos eines Buckets, für seine Zeile. */
    fun openTodos(projectID: String, notes: List<Note>): Int = elements(projectID, notes).count { it.isTodo && !it.isDone }

    /** Letzte Änderung: die des Projekts selbst oder die des neuesten Eintrags. */
    fun lastChange(project: NoteFolder, notes: List<Note>): Long =
        maxOf(project.updatedAt, project.createdAt, elements(project.id, notes).maxOfOrNull { it.updatedAt } ?: 0)

    /** Anzahl der Einträge je Projekt. */
    fun counts(projectIDs: Collection<String>, notes: List<Note>): Map<String, Int> =
        projectIDs.associateWith { elements(it, notes).size }

    fun toggled(ids: List<String>, id: String): List<String> = if (id in ids) ids - id else ids + id

    /** Nach dem Löschen eines Projekts: die geänderten Notizen ohne seine ID (sie selbst bleiben). */
    fun removing(projectID: String, notes: List<Note>, now: Long): List<Note> =
        notes.filter { projectID in it.projectIDs }.map { it.copy(projectIDs = it.projectIDs - projectID, updatedAt = now) }

    /** Ordner werden Projekte: jede Notiz mit `folderID` gehört danach zu diesem Projekt; nur Geänderte kommen zurück. */
    fun migrateFolders(notes: List<Note>, now: Long): List<Note> =
        notes.filter { it.folderID != null }.map { note ->
            val folder = note.folderID!!
            note.copy(projectIDs = if (folder in note.projectIDs) note.projectIDs else note.projectIDs + folder, folderID = null, updatedAt = now)
        }
}

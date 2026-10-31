package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note

/**
 * iOS: `ProjectsLogic` — wer zu einem Projekt gehört. Notizen, Meetings und Links über ihre `projectIDs`,
 * Aufgaben über ihre eigenen oder die der Notiz, aus der sie stammen.
 */
object ProjectsLogic {
    enum class Kind(val title: String) { MEETING("Meetings"), NOTE("Notes"), LINK("Links"), TASK("Tasks") }

    /** Ein Eintrag eines Projekts: eine Notiz (auch Meeting oder Link) oder eine Aufgabe mit ihrer Notiz. */
    sealed interface Element {
        val id: String
        val kind: Kind
        val date: Long

        data class NoteElement(val note: Note) : Element {
            override val id get() = note.id
            override val kind get() = kind(note)
            override val date get() = note.updatedAt
        }

        data class TaskElement(val item: ActionItem, val note: Note?) : Element {
            override val id get() = item.id
            override val kind get() = Kind.TASK
            override val date get() = item.updatedAt
        }
    }

    fun kind(note: Note): Kind = when {
        note.isLink -> Kind.LINK
        note.isRecording -> Kind.MEETING
        else -> Kind.NOTE
    }

    /** Die Aufgabe gehört zum Projekt: selbst zugeordnet oder über ihre Notiz. */
    fun itemInProject(item: ActionItem, projectID: String, notesByID: Map<String, Note>): Boolean =
        projectID in item.projectIDs || item.noteID?.let { notesByID[it] }?.projectIDs?.contains(projectID) == true

    /** Projekte, die eine Aufgabe von ihrer Notiz erbt (dort nicht abwählbar). */
    fun inherited(item: ActionItem, note: Note?): List<String> = note?.projectIDs.orEmpty()

    /** Alles eines Projekts, neueste zuerst; gelöschte Notizen (und ihre Aufgaben) und verworfene Aufgaben fehlen. */
    fun elements(projectID: String, notes: List<Note>, items: List<ActionItem>): List<Element> {
        val byID = notes.associateBy { it.id }
        val noteElements = notes.filter { !it.isDeleted && projectID in it.projectIDs }.map { Element.NoteElement(it) }
        val taskElements = items.mapNotNull { item ->
            if (item.kind != ActionItem.Kind.TASK || item.review == ActionItem.Review.DISMISSED) return@mapNotNull null
            val note = item.noteID?.let { byID[it] }
            if (note?.isDeleted == true) return@mapNotNull null
            if (itemInProject(item, projectID, byID)) Element.TaskElement(item, note) else null
        }
        return (noteElements + taskElements).sortedByDescending { it.date }
    }

    /** Anzahl der Einträge je Projekt. */
    fun counts(projectIDs: Collection<String>, notes: List<Note>, items: List<ActionItem>): Map<String, Int> =
        projectIDs.associateWith { elements(it, notes, items).size }

    fun toggled(ids: List<String>, id: String): List<String> = if (id in ids) ids - id else ids + id

    /** Nach dem Löschen eines Projekts: die geänderten Notizen und Aufgaben ohne seine ID (sie selbst bleiben). */
    fun removing(projectID: String, notes: List<Note>, items: List<ActionItem>, now: Long): Pair<List<Note>, List<ActionItem>> =
        notes.filter { projectID in it.projectIDs }.map { it.copy(projectIDs = it.projectIDs - projectID, updatedAt = now) } to
            items.filter { projectID in it.projectIDs }.map { it.copy(projectIDs = it.projectIDs - projectID, updatedAt = now) }

    /** Ordner werden Projekte: jede Notiz mit `folderID` gehört danach zu diesem Projekt; nur Geänderte kommen zurück. */
    fun migrateFolders(notes: List<Note>, now: Long): List<Note> =
        notes.filter { it.folderID != null }.map { note ->
            val folder = note.folderID!!
            note.copy(projectIDs = if (folder in note.projectIDs) note.projectIDs else note.projectIDs + folder, folderID = null, updatedAt = now)
        }
}

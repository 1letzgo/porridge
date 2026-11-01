package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.sync.SyncMerge
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeListLogicTest {
    private val active = NoteFolder(id = "ACTIVE", name = "Active")
    private val archived = NoteFolder(id = "ARCHIVED", name = "Archived", archivedAt = 5)
    private val folders = listOf(active, archived)

    private fun homeTaskIDs(items: List<ActionItem>, notes: List<Note> = emptyList()) =
        HomeListLogic.homeTasks(items, notes, folders).map { it.first.id }

    @Test fun homeNotesHideDeletedArchivedAndThoseInProjects() {
        val notes = listOf(
            Note(id = "plain", updatedAt = 1),
            Note(id = "meeting", audioFileName = "a.m4a", updatedAt = 3),
            Note(id = "link", url = "https://example.com", updatedAt = 2),
            Note(id = "deleted", deletedAt = 1),
            Note(id = "archived", archivedAt = 1),
            Note(id = "inProject", projectIDs = listOf("ACTIVE")),
            Note(id = "inArchivedOnly", projectIDs = listOf("ARCHIVED")),
        )
        assertEquals(listOf("meeting", "link", "plain"), HomeListLogic.homeNotes(notes, folders).map { it.id })
    }

    @Test fun staleProjectIDsDoNotHide() {
        val note = Note(id = "N", projectIDs = listOf("GONE"))
        assertEquals(listOf("N"), HomeListLogic.homeNotes(listOf(note), folders).map { it.id })
        assertEquals(listOf("T"), homeTaskIDs(listOf(ActionItem(id = "T", projectIDs = listOf("GONE")))))
        // Auch über die Notiz: ihre verwaiste ID versteckt die Aufgabe nicht, eine lebende neben ihr schon.
        assertEquals(listOf("V"), homeTaskIDs(listOf(ActionItem(id = "V", noteID = "N")), listOf(note)))
        val both = Note(id = "B", projectIDs = listOf("GONE", "ACTIVE"))
        assertEquals(emptyList<String>(), HomeListLogic.homeNotes(listOf(both), folders).map { it.id })
        assertEquals(emptyList<String>(), homeTaskIDs(listOf(ActionItem(id = "W", noteID = "B")), listOf(both)))
    }

    @Test fun homeTasksFollowProjectsDirectlyAndThroughTheirNote() {
        val inProject = Note(id = "P", projectIDs = listOf("ACTIVE"))
        val inArchived = Note(id = "A", projectIDs = listOf("ARCHIVED"))
        val free = Note(id = "F")
        val items = listOf(
            ActionItem(id = "free", noteID = "F"),
            ActionItem(id = "own", source = "manual"),
            ActionItem(id = "direct", projectIDs = listOf("ACTIVE")),
            ActionItem(id = "viaNote", noteID = "P"),
            ActionItem(id = "viaArchivedNote", noteID = "A"),
            ActionItem(id = "directArchived", projectIDs = listOf("ARCHIVED")),
            ActionItem(id = "archived", archivedAt = 1),
        )
        assertEquals(setOf("free", "own"), homeTaskIDs(items, listOf(inProject, inArchived, free)).toSet())
    }

    @Test fun tasksSkipDismissedDecisionsDeletedNotesAndLinks() {
        val deleted = Note(id = "D", deletedAt = 1)
        val link = Note(id = "L", url = "https://example.com")
        val items = listOf(
            ActionItem(id = "ok"),
            ActionItem(id = "dismissed", reviewRaw = ActionItem.Review.DISMISSED.raw),
            ActionItem(id = "decision", kindRaw = ActionItem.Kind.DECISION.raw),
            ActionItem(id = "fromDeleted", noteID = "D"),
            ActionItem(id = "fromLink", noteID = "L"),
            // Die Notiz ist endgültig weg: die Aufgabe bleibt eigenständig.
            ActionItem(id = "orphan", noteID = "missing"),
        )
        assertEquals(setOf("ok", "orphan"), homeTaskIDs(items, listOf(deleted, link)).toSet())
        // Links geben auch im Projekt, im Archiv und in der Suche keine Aufgaben.
        val fromLink = ActionItem(id = "T", noteID = "L", projectIDs = listOf("ACTIVE"), text = "word", archivedAt = 1)
        assertEquals(emptyList<String>(), HomeListLogic.archivedTasks(listOf(fromLink), listOf(link)).map { it.first.id })
        assertEquals(emptyList<String>(), HomeListLogic.searchTasks(listOf(fromLink), listOf(link), "word", emptyList(), null).map { it.first.id })
        val open = fromLink.copy(archivedAt = null)
        assertEquals(emptyList<String>(), ProjectsLogic.elements("ACTIVE", listOf(link), listOf(open)).map { it.id })
    }

    @Test fun archivingANoteLeavesItsTasks() {
        val note = Note(id = "N", archivedAt = 1)
        val task = ActionItem(id = "T", noteID = "N")
        assertEquals(emptyList<Note>(), HomeListLogic.homeNotes(listOf(note), folders))
        assertEquals(listOf("T"), homeTaskIDs(listOf(task), listOf(note)))
        assertEquals(emptyList<String>(), HomeListLogic.archivedTasks(listOf(task), listOf(note)).map { it.first.id })
        // Auf der Projektseite genauso: die Notiz fehlt, die Aufgabe bleibt.
        val inProject = note.copy(projectIDs = listOf("ACTIVE"))
        assertEquals(listOf("T"), ProjectsLogic.elements("ACTIVE", listOf(inProject), listOf(task)).map { it.id })
    }

    @Test fun archivingAProjectLeavesItsElementsInIt() {
        val shared = Note(id = "shared", projectIDs = listOf("ACTIVE", "ARCHIVED"))
        val only = Note(id = "only", projectIDs = listOf("ARCHIVED"))
        val notes = listOf(shared, only)
        // Weder auf der Startseite noch im Archiv; sie bleiben in ihren Projekten.
        assertEquals(emptyList<Note>(), HomeListLogic.homeNotes(notes, folders))
        assertEquals(emptyList<Note>(), HomeListLogic.archivedNotes(notes))
        assertEquals(listOf("shared"), ProjectsLogic.elements("ACTIVE", notes, emptyList()).map { it.id })
        assertEquals(setOf("shared", "only"), ProjectsLogic.elements("ARCHIVED", notes, emptyList()).map { it.id }.toSet())
    }

    @Test fun projectsAreSplitByArchive() {
        assertEquals(listOf("ACTIVE"), HomeListLogic.activeProjects(folders).map { it.id })
        assertEquals(listOf("ARCHIVED"), HomeListLogic.archivedProjects(folders).map { it.id })
    }

    @Test fun projectPagesHideArchivedContents() {
        val notes = listOf(Note(id = "N", projectIDs = listOf("P")), Note(id = "A", projectIDs = listOf("P"), archivedAt = 1))
        val items = listOf(ActionItem(id = "T", projectIDs = listOf("P")), ActionItem(id = "U", projectIDs = listOf("P"), archivedAt = 1))
        assertEquals(setOf("N", "T"), ProjectsLogic.elements("P", notes, items).map { it.id }.toSet())
        assertEquals(mapOf("P" to 2), ProjectsLogic.counts(listOf("P"), notes, items))
    }

    @Test fun archiveListsWhatIsArchivedAndNotDeleted() {
        val notes = listOf(
            Note(id = "old", archivedAt = 1, updatedAt = 1),
            Note(id = "new", archivedAt = 2, updatedAt = 2, projectIDs = listOf("ACTIVE")),
            Note(id = "trashed", archivedAt = 3, deletedAt = 4),
            Note(id = "open"),
            Note(id = "D", deletedAt = 1),
        )
        val items = listOf(
            ActionItem(id = "T", archivedAt = 1, projectIDs = listOf("ACTIVE")),
            ActionItem(id = "U"),
            ActionItem(id = "fromDeleted", noteID = "D", archivedAt = 1),
        )
        assertEquals(listOf("new", "old"), HomeListLogic.archivedNotes(notes).map { it.id })
        assertEquals(listOf("T"), HomeListLogic.archivedTasks(items, notes).map { it.first.id })
        assertEquals(4, HomeListLogic.archiveCount(folders, notes, items))
    }

    @Test fun trashingAndRestoringKeepsTheArchive() {
        // NoteStore.trash und restore ändern nur `deletedAt` (und den Pin).
        val note = Note(id = "N", archivedAt = 7)
        val trashed = note.copy(deletedAt = 9, isPinned = false)
        assertEquals(emptyList<Note>(), HomeListLogic.archivedNotes(listOf(trashed)))
        val restored = trashed.copy(deletedAt = null)
        assertEquals(listOf("N"), HomeListLogic.archivedNotes(listOf(restored)).map { it.id })
        assertEquals(emptyList<Note>(), HomeListLogic.homeNotes(listOf(restored), folders))
    }

    @Test fun sectionsSplitNewMineGeneralAndDone() {
        val tasks = HomeListLogic.tasks(
            listOf(
                ActionItem(id = "new", reviewRaw = ActionItem.Review.PENDING.raw),
                ActionItem(id = "mine", source = "manual"),
                ActionItem(id = "general", owner = "Ben"),
                ActionItem(id = "done", isDone = true, reviewRaw = ActionItem.Review.PENDING.raw),
            ),
            emptyList(),
        )
        val sections = HomeListLogic.sections(tasks, listOf("anna"))
        assertEquals(listOf("new"), sections.new.map { it.first.id })
        assertEquals(listOf("mine"), sections.mine.map { it.first.id })
        assertEquals(listOf("general"), sections.general.map { it.first.id })
        assertEquals(listOf("done"), sections.done.map { it.first.id })
    }

    @Test fun searchFindsArchivedNotesByKindAndTag() {
        val notes = listOf(
            Note(id = "note", text = "hello #work", updatedAt = 3),
            Note(id = "archived", text = "hello", archivedAt = 1, updatedAt = 2),
            Note(id = "meeting", text = "hello", audioFileName = "a.m4a", updatedAt = 1),
            Note(id = "link", text = "hello", url = "https://example.com", updatedAt = 0),
            Note(id = "deleted", text = "hello", deletedAt = 1),
            Note(id = "other", text = "bye"),
        )
        fun ids(query: String = "hello", tags: List<String> = emptyList(), kind: ProjectsLogic.Kind? = null, index: Set<String>? = null) =
            HomeListLogic.searchNotes(notes, query, tags, kind, index).map { it.id }
        assertEquals(listOf("note", "archived", "meeting", "link"), ids())
        assertEquals(listOf("meeting"), ids(kind = ProjectsLogic.Kind.MEETING))
        assertEquals(listOf("link"), ids(kind = ProjectsLogic.Kind.LINK))
        assertEquals(listOf("note", "archived"), ids(kind = ProjectsLogic.Kind.NOTE))
        assertEquals(emptyList<String>(), ids(kind = ProjectsLogic.Kind.TASK))
        assertEquals(listOf("note"), ids(tags = listOf("work")))
        // Nur eine Art gewählt, ohne Anfrage: alles dieser Art.
        assertEquals(listOf("meeting"), ids(query = "", kind = ProjectsLogic.Kind.MEETING))
        // Der Index entscheidet, wenn er bereit ist.
        assertEquals(listOf("other"), ids(index = setOf("other", "deleted")))
    }

    @Test fun searchFindsTasksIncludingArchived() {
        val tagged = Note(id = "N", text = "#work")
        val items = listOf(
            ActionItem(id = "text", text = "Call Anna", noteID = "N", createdAt = 3),
            ActionItem(id = "details", details = "call back", createdAt = 2),
            ActionItem(id = "archived", text = "Call Ben", archivedAt = 1, createdAt = 1),
            ActionItem(id = "other", text = "Write"),
        )
        fun ids(query: String = "call", tags: List<String> = emptyList(), kind: ProjectsLogic.Kind? = null) =
            HomeListLogic.searchTasks(items, listOf(tagged), query, tags, kind).map { it.first.id }.toSet()
        assertEquals(setOf("text", "details", "archived"), ids())
        assertEquals(setOf("text", "details", "archived"), ids(kind = ProjectsLogic.Kind.TASK))
        assertEquals(emptySet<String>(), ids(kind = ProjectsLogic.Kind.NOTE))
        // Tags kommen von der Notiz; eigene Aufgaben ohne Notiz fallen dann weg.
        assertEquals(setOf("text"), ids(tags = listOf("work")))
        assertTrue(HomeListLogic.matches(ActionItem(owner = "Anna"), "anna"))
        assertFalse(HomeListLogic.matches(ActionItem(text = "Call"), "call anna"))
    }

    @Test fun syncCarriesArchivedAtInMillisecondsForAllThree() {
        val note = PorridgeJson.encodeToJsonElement(Note.serializer(), Note(archivedAt = 1234)).jsonObject
        val item = PorridgeJson.encodeToJsonElement(ActionItem.serializer(), ActionItem(archivedAt = 1234)).jsonObject
        val folder = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), NoteFolder(archivedAt = 1234)).jsonObject
        for (record in listOf(note, item, folder)) assertEquals("1234", record["archivedAt"].toString())
        assertEquals(1234L, PorridgeJson.decodeFromJsonElement(Note.serializer(), note).archivedAt)
        assertEquals(1234L, PorridgeJson.decodeFromJsonElement(ActionItem.serializer(), item).archivedAt)
        assertEquals(1234L, PorridgeJson.decodeFromJsonElement(NoteFolder.serializer(), folder).archivedAt)
    }

    @Test fun notArchivedLeavesSyncRecordsUntouched() {
        // Ohne Wert fehlt das Feld: der Hash bleibt, das Update schreibt nicht jeden Eintrag neu in die Datei.
        val folder = NoteFolder(id = "F", name = "A", createdAt = 1, updatedAt = 2)
        val record = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), folder).jsonObject
        assertFalse("archivedAt" in record)
        val older = PorridgeJson.parseToJsonElement("""{"id":"F","name":"A","createdAt":1,"updatedAt":2}""").jsonObject
        assertEquals(SyncMerge.hash(older), SyncMerge.hash(record))
        assertEquals(null, PorridgeJson.decodeFromJsonElement(NoteFolder.serializer(), older).archivedAt)
    }
}

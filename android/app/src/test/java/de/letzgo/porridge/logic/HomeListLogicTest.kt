package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
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

    @Test fun everyEntryHasOneKind() {
        val notes = listOf(
            Note(id = "plain"), Note(id = "meeting", audioFileName = "a.m4a"), Note(id = "link", url = "https://example.com"),
            Note(id = "file", sourceRaw = "share", attachmentsData = """[{"id":"A","fileName":"a.pdf","name":"Invoice.pdf","kindRaw":"pdf"}]"""),
            Note(id = "image", sourceRaw = "share", attachmentsData = """[{"id":"B","fileName":"b.png","name":"Screenshot.png","kindRaw":"image"}]"""),
            // Eine Notiz mit angehängter Datei bleibt eine Notiz.
            Note(id = "attached", sourceRaw = "note", attachmentsData = "[]"),
        )
        fun shown(kind: ProjectsLogic.Kind) = notes.filter { ProjectsLogic.kind(it) == kind }.map { it.id }
        assertEquals(listOf("meeting"), shown(ProjectsLogic.Kind.MEETING))
        assertEquals(listOf("plain", "attached"), shown(ProjectsLogic.Kind.NOTE))
        assertEquals(listOf("link"), shown(ProjectsLogic.Kind.LINK))
        assertEquals(listOf("file"), shown(ProjectsLogic.Kind.FILE))
        assertEquals(listOf("image"), shown(ProjectsLogic.Kind.IMAGE))
    }

    @Test fun archivingANoteTakesItOffTheHomeList() {
        val note = Note(id = "N", archivedAt = 1)
        assertEquals(emptyList<Note>(), InboxLogic.notes(listOf(note)))
        assertEquals(emptyList<Note>(), ProjectsLogic.elements("ACTIVE", listOf(note.copy(projectIDs = listOf("ACTIVE")))))
    }

    @Test fun archivingAProjectLeavesItsElementsInIt() {
        val shared = Note(id = "shared", projectIDs = listOf("ACTIVE", "ARCHIVED"))
        val only = Note(id = "only", projectIDs = listOf("ARCHIVED"))
        val notes = listOf(shared, only)
        // Weder auf der Startseite noch im Archiv; sie bleiben in ihren Projekten.
        assertEquals(emptyList<Note>(), InboxLogic.notes(notes))
        assertEquals(emptyList<Note>(), HomeListLogic.archivedNotes(notes))
        assertEquals(listOf("shared"), ProjectsLogic.elements("ACTIVE", notes).map { it.id })
        assertEquals(setOf("shared", "only"), ProjectsLogic.elements("ARCHIVED", notes).map { it.id }.toSet())
    }

    @Test fun projectsAreSplitByArchive() {
        assertEquals(listOf("ACTIVE"), HomeListLogic.activeProjects(folders).map { it.id })
        assertEquals(listOf("ARCHIVED"), HomeListLogic.archivedProjects(folders).map { it.id })
    }

    @Test fun listShowsAllPinnedAndTheLatestFiveOthers() {
        val others = (1..7).map { NoteFolder(id = "P$it", name = "P$it", updatedAt = it.toLong()) }
        val pinned = (1..6).map { NoteFolder(id = "PIN$it", name = "Pin$it", updatedAt = 0, isPinned = true) }
        val few = HomeListLogic.shownProjects(others + pinned, showAll = false) { it.updatedAt }
        assertEquals(pinned.map { it.id } + listOf("P7", "P6", "P5", "P4", "P3"), few.shown.map { it.id })
        assertEquals(2, few.hidden)
        val all = HomeListLogic.shownProjects(others + pinned, showAll = true) { it.updatedAt }
        assertEquals(13, all.shown.size)
        assertEquals(2, all.hidden)
    }

    @Test fun moreIsNotNeededForFiveProjects() {
        val five = (1..5).map { NoteFolder(id = "P$it", name = "P$it") }
        assertEquals(0, HomeListLogic.shownProjects(five, showAll = false) { 0 }.hidden)
    }

    @Test fun projectPinSurvivesTheJson() {
        val folder = NoteFolder(id = "P", isPinned = true)
        val text = PorridgeJson.encodeToString(NoteFolder.serializer(), folder)
        assertTrue(PorridgeJson.decodeFromString(NoteFolder.serializer(), text).isPinned)
    }

    @Test fun projectPagesHideArchivedContents() {
        val notes = listOf(Note(id = "N", projectIDs = listOf("P")), Note(id = "A", projectIDs = listOf("P"), archivedAt = 1))
        assertEquals(listOf("N"), ProjectsLogic.elements("P", notes).map { it.id })
        assertEquals(mapOf("P" to 1), ProjectsLogic.counts(listOf("P"), notes))
    }

    @Test fun archiveListsWhatIsArchivedAndNotDeleted() {
        val notes = listOf(
            Note(id = "old", archivedAt = 1, updatedAt = 1),
            Note(id = "new", archivedAt = 2, updatedAt = 2, projectIDs = listOf("ACTIVE")),
            Note(id = "trashed", archivedAt = 3, deletedAt = 4),
            Note(id = "open"),
            Note(id = "D", deletedAt = 1),
        )
        assertEquals(listOf("new", "old"), HomeListLogic.archivedNotes(notes).map { it.id })
        assertEquals(3, HomeListLogic.archiveCount(folders, notes))
    }

    @Test fun trashingAndRestoringKeepsTheArchive() {
        // NoteStore.trash und restore ändern nur `deletedAt` (und den Pin).
        val note = Note(id = "N", archivedAt = 7)
        val trashed = note.copy(deletedAt = 9, isPinned = false)
        assertEquals(emptyList<Note>(), HomeListLogic.archivedNotes(listOf(trashed)))
        val restored = trashed.copy(deletedAt = null)
        assertEquals(listOf("N"), HomeListLogic.archivedNotes(listOf(restored)).map { it.id })
        assertEquals(emptyList<Note>(), InboxLogic.notes(listOf(restored)))
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
        assertEquals(listOf("note"), ids(tags = listOf("work")))
        // Nur eine Art gewählt, ohne Anfrage: alles dieser Art.
        assertEquals(listOf("meeting"), ids(query = "", kind = ProjectsLogic.Kind.MEETING))
        // Der Index entscheidet, wenn er bereit ist.
        assertEquals(listOf("other"), ids(index = setOf("other", "deleted")))
    }

        @Test fun syncCarriesArchivedAtInMilliseconds() {
        val note = PorridgeJson.encodeToJsonElement(Note.serializer(), Note(archivedAt = 1234)).jsonObject
        val folder = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), NoteFolder(archivedAt = 1234)).jsonObject
        for (record in listOf(note, folder)) assertEquals("1234", record["archivedAt"].toString())
        assertEquals(1234L, PorridgeJson.decodeFromJsonElement(Note.serializer(), note).archivedAt)
        assertEquals(1234L, PorridgeJson.decodeFromJsonElement(NoteFolder.serializer(), folder).archivedAt)
    }

    @Test fun notArchivedLeavesSyncRecordsUntouched() {
        // Ohne Wert fehlt das Feld: der Hash bleibt, das Update schreibt nicht jeden Eintrag neu in die Datei.
        val folder = NoteFolder(id = "F", name = "A", createdAt = 1, updatedAt = 2)
        val record = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), folder).jsonObject
        assertFalse("archivedAt" in record)
        assertFalse("isPinned" in record)
        val older = PorridgeJson.parseToJsonElement("""{"id":"F","name":"A","createdAt":1,"updatedAt":2}""").jsonObject
        assertEquals(SyncMerge.hash(older), SyncMerge.hash(record))
        assertEquals(null, PorridgeJson.decodeFromJsonElement(NoteFolder.serializer(), older).archivedAt)
    }

    @Test fun recordingNotesBecomeListItemsWithTheirTime() {
        val notes = listOf(de.letzgo.porridge.model.RecordingNote(65.0, "Ask about pricing"), de.letzgo.porridge.model.RecordingNote(3725.0, "Send the plan"))
        assertEquals("- 1:05 Ask about pricing\n- 1:02:05 Send the plan", de.letzgo.porridge.model.RecordingNote.markdown(notes))
    }

    @Test fun anOldBackupWithTasksStillReads() {
        val old = """{"version":1,"notes":[{"id":"N"}],"folders":[],"voiceProfiles":[],"actionItems":[{"id":"T","text":"Call"}]}"""
        val contents = PorridgeJson.decodeFromString(de.letzgo.porridge.data.Backup.Contents.serializer(), old)
        assertEquals(listOf("N"), contents.notes.map { it.id })
        assertFalse("actionItems" in PorridgeJson.encodeToJsonElement(de.letzgo.porridge.data.Backup.Contents.serializer(), contents).jsonObject)
    }

    @Test fun recommendedModelFollowsTheMemory() {
        assertEquals(de.letzgo.porridge.ml.LocalModel.NEMOTRON_BOLT, de.letzgo.porridge.ml.LocalModel.recommended(12.0))
        assertEquals(de.letzgo.porridge.ml.LocalModel.QWEN3, de.letzgo.porridge.ml.LocalModel.recommended(8.0))
        assertEquals(de.letzgo.porridge.ml.LocalModel.QWEN3_SMALL, de.letzgo.porridge.ml.LocalModel.recommended(6.0))
    }
}

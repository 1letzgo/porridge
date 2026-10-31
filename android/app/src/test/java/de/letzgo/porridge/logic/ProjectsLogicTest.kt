package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectsLogicTest {
    private val p = "P1"

    @Test fun itemInProjectDirectlyOrViaNote() {
        val note = Note(id = "N", projectIDs = listOf(p))
        val other = Note(id = "O")
        val byID = listOf(note, other).associateBy { it.id }
        assertTrue(ProjectsLogic.itemInProject(ActionItem(projectIDs = listOf(p)), p, byID))
        assertTrue(ProjectsLogic.itemInProject(ActionItem(noteID = "N"), p, byID))
        assertFalse(ProjectsLogic.itemInProject(ActionItem(noteID = "O"), p, byID))
        assertFalse(ProjectsLogic.itemInProject(ActionItem(), p, byID))
        assertFalse(ProjectsLogic.itemInProject(ActionItem(noteID = "missing"), p, byID))
    }

    @Test fun elementsExcludeDeletedNotesAndSortNewestFirst() {
        val note = Note(id = "A", projectIDs = listOf(p), updatedAt = 100)
        val meeting = Note(id = "M", projectIDs = listOf(p), audioFileName = "a.m4a", updatedAt = 300)
        val link = Note(id = "L", projectIDs = listOf(p), url = "https://example.com", updatedAt = 200)
        val deleted = Note(id = "D", projectIDs = listOf(p), deletedAt = 1, updatedAt = 999)
        val outside = Note(id = "X", updatedAt = 500)
        val viaNote = ActionItem(id = "T1", noteID = "A", updatedAt = 400)
        val direct = ActionItem(id = "T2", projectIDs = listOf(p), updatedAt = 50)
        val fromDeleted = ActionItem(id = "T3", noteID = "D", projectIDs = listOf(p), updatedAt = 600)
        val dismissed = ActionItem(id = "T4", projectIDs = listOf(p), reviewRaw = ActionItem.Review.DISMISSED.raw)
        val decision = ActionItem(id = "T5", projectIDs = listOf(p), kindRaw = ActionItem.Kind.DECISION.raw)
        val unrelated = ActionItem(id = "T6", noteID = "X")

        val elements = ProjectsLogic.elements(p, listOf(note, meeting, link, deleted, outside), listOf(viaNote, direct, fromDeleted, dismissed, decision, unrelated))
        assertEquals(listOf("T1", "M", "L", "A", "T2"), elements.map { it.id })
        assertEquals(
            listOf(ProjectsLogic.Kind.TASK, ProjectsLogic.Kind.MEETING, ProjectsLogic.Kind.LINK, ProjectsLogic.Kind.NOTE, ProjectsLogic.Kind.TASK),
            elements.map { it.kind },
        )
        assertEquals(mapOf(p to 5, "empty" to 0), ProjectsLogic.counts(listOf(p, "empty"), listOf(note, meeting, link, deleted, outside), listOf(viaNote, direct, fromDeleted)))
    }

    @Test fun deleteRemovesIDsButKeepsElements() {
        val notes = listOf(Note(id = "A", projectIDs = listOf(p, "P2"), updatedAt = 1), Note(id = "B", projectIDs = listOf("P2"), updatedAt = 1))
        val items = listOf(ActionItem(id = "T", projectIDs = listOf(p), updatedAt = 1), ActionItem(id = "U", updatedAt = 1))
        val (changedNotes, changedItems) = ProjectsLogic.removing(p, notes, items, now = 42)
        assertEquals(listOf("A"), changedNotes.map { it.id })
        assertEquals(listOf("P2"), changedNotes[0].projectIDs)
        assertEquals(42L, changedNotes[0].updatedAt)
        assertEquals(listOf("T"), changedItems.map { it.id })
        assertEquals(emptyList<String>(), changedItems[0].projectIDs)
        assertEquals(42L, changedItems[0].updatedAt)
    }

    @Test fun toggleAddsAndRemoves() {
        assertEquals(listOf("a", "b"), ProjectsLogic.toggled(listOf("a"), "b"))
        assertEquals(listOf("a"), ProjectsLogic.toggled(listOf("a", "b"), "b"))
    }

    @Test fun foldersBecomeProjects() {
        val inFolder = Note(id = "A", folderID = "F", updatedAt = 1)
        val already = Note(id = "B", folderID = "F", projectIDs = listOf("F"), updatedAt = 1)
        val plain = Note(id = "C", updatedAt = 1)
        val changed = ProjectsLogic.migrateFolders(listOf(inFolder, already, plain), now = 7)
        assertEquals(listOf("A", "B"), changed.map { it.id })
        assertTrue(changed.all { it.folderID == null && it.projectIDs == listOf("F") && it.updatedAt == 7L })
        // Ein zweiter Lauf ändert nichts mehr.
        assertEquals(emptyList<Note>(), ProjectsLogic.migrateFolders(changed, now = 8))
    }

    @Test fun jsonUsesProjectIDsAndUpdatedAt() {
        val note = PorridgeJson.encodeToJsonElement(Note.serializer(), Note(projectIDs = listOf("F"))).jsonObject
        assertTrue("projectIDs" in note)
        val item = PorridgeJson.encodeToJsonElement(ActionItem.serializer(), ActionItem(projectIDs = listOf("F"))).jsonObject
        assertTrue("projectIDs" in item)
        val folder = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), NoteFolder(updatedAt = 5)).jsonObject
        assertEquals("5", folder["updatedAt"].toString())
        // Ältere Datensätze ohne die Felder lesen sich mit leeren Werten.
        val old = PorridgeJson.decodeFromString(Note.serializer(), """{"id":"X"}""")
        assertEquals(emptyList<String>(), old.projectIDs)
    }
}

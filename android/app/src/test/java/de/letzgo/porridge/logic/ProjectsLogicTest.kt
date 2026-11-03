package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectsLogicTest {
    private val p = "P1"

        @Test fun elementsExcludeDeletedNotesAndSortNewestFirst() {
        val note = Note(id = "A", projectIDs = listOf(p), updatedAt = 100)
        val meeting = Note(id = "M", projectIDs = listOf(p), audioFileName = "a.m4a", updatedAt = 300)
        val link = Note(id = "L", projectIDs = listOf(p), url = "https://example.com", updatedAt = 200)
        val deleted = Note(id = "D", projectIDs = listOf(p), deletedAt = 1, updatedAt = 999)
        val outside = Note(id = "X", updatedAt = 500)
        val all = listOf(note, meeting, link, deleted, outside)
        val elements = ProjectsLogic.elements(p, all)
        assertEquals(listOf("M", "L", "A"), elements.map { it.id })
        assertEquals(listOf(ProjectsLogic.Kind.MEETING, ProjectsLogic.Kind.LINK, ProjectsLogic.Kind.NOTE), elements.map(ProjectsLogic::kind))
        assertEquals(mapOf(p to 3, "empty" to 0), ProjectsLogic.counts(listOf(p, "empty"), all))
    }

    @Test fun deleteRemovesIDsButKeepsElements() {
        val notes = listOf(Note(id = "A", projectIDs = listOf(p, "P2"), updatedAt = 1), Note(id = "B", projectIDs = listOf("P2"), updatedAt = 1))
        val changed = ProjectsLogic.removing(p, notes, now = 42)
        assertEquals(listOf("A"), changed.map { it.id })
        assertEquals(listOf("P2"), changed[0].projectIDs)
        assertEquals(42L, changed[0].updatedAt)
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
        val folder = PorridgeJson.encodeToJsonElement(NoteFolder.serializer(), NoteFolder(updatedAt = 5)).jsonObject
        assertEquals("5", folder["updatedAt"].toString())
        // Ältere Datensätze ohne die Felder lesen sich mit leeren Werten.
        val old = PorridgeJson.decodeFromString(Note.serializer(), """{"id":"X"}""")
        assertEquals(emptyList<String>(), old.projectIDs)
    }
}

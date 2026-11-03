package de.letzgo.porridge.index

import de.letzgo.porridge.model.Note
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NoteIndexTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun refreshesChangedNotesAndPersists() = runTest {
        val file = folder.root.resolve("index.bin")
        val index = NoteIndex(file, this)
        val a = Note(id = "A", text = "Budget für Q3")
        val b = Note(id = "B", text = "Urlaub an der Ostsee")
        index.refresh(listOf(a, b))
        index.idle()
        assertEquals(setOf("A"), index.noteIDs("budget"))
        assertEquals(setOf("B"), index.noteIDs("ostsee"))

        index.refresh(listOf(a, b.copy(text = "Urlaub in den Bergen")))
        index.idle()
        assertEquals(emptySet<String>(), index.noteIDs("ostsee"))
        assertEquals(setOf("B"), index.noteIDs("bergen"))

        index.refresh(listOf(a))
        index.idle()
        assertEquals(setOf("A"), index.noteIDs(""))

        val reloaded = NoteIndex(file, this)
        reloaded.refresh(listOf(a))
        reloaded.idle()
        assertEquals(setOf("A"), reloaded.noteIDs("budget"))
    }
}

package de.letzgo.porridge.index

import de.letzgo.porridge.ml.SentenceEmbedder
import de.letzgo.porridge.model.Note
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NoteIndexTest {
    @get:Rule val folder = TemporaryFolder()

    private class CountingEmbedder : SentenceEmbedder {
        var calls = 0
        override suspend fun isAvailable() = true
        override suspend fun vector(text: String): FloatArray { calls++; return floatArrayOf(text.length.toFloat(), 1f) }
    }

    @Test fun refreshesOnlyChangedNotesAndPersists() = runTest {
        val embedder = CountingEmbedder()
        val file = folder.root.resolve("index.bin")
        val index = NoteIndex(file, { embedder }, this)
        val a = Note(id = "A", text = "Budget für Q3")
        val b = Note(id = "B", text = "Urlaub an der Ostsee")
        index.refresh(listOf(a, b))
        index.idle()
        assertEquals(2, embedder.calls)
        assertEquals(setOf("A"), index.noteIDs("budget"))
        assertTrue(index.chunks.all { it.embedding != null })

        index.refresh(listOf(a, b.copy(text = "Urlaub in den Bergen")))
        index.idle()
        assertEquals(3, embedder.calls)
        index.refresh(listOf(a))
        index.idle()
        assertEquals(setOf("A"), index.noteIDs(""))

        val reloaded = NoteIndex(file, { embedder }, this)
        reloaded.refresh(listOf(a))
        reloaded.idle()
        assertEquals(3, embedder.calls)
        assertEquals(1, reloaded.chunks.size)
        assertTrue(reloaded.chunks.single().embedding != null)
    }
}

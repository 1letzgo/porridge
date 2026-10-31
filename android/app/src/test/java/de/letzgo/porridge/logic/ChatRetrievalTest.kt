package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.Speaker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatRetrievalTest {
    @Test fun tokensLikeNLTokenizer() {
        // Kleinbuchstaben, nur Wörter mit mindestens zwei Zeichen, keine Satzzeichen.
        // Erwartungen aus iOS (NLTokenizer, ausgeführt auf macOS 27).
        assertEquals(listOf("das", "budget", "für", "q3", "steht", "mail"), ChatRetrieval.tokens("Das Budget für Q3 steht: a, E-Mail!"))
        assertEquals(
            listOf("ich", "hab's", "3.5", "mio", "am", "12.10.2026", "um", "14", "30", "co", "op"),
            ChatRetrieval.tokens("Ich hab's 3.5 Mio. € am 12.10.2026 um 14:30 – co-op"),
        )
        assertEquals(listOf("grüße", "ça", "va", "tag", "foo", "bar", "2x"), ChatRetrieval.tokens("Grüße, ça va? #tag foo_bar 2x"))
    }

    @Test fun piecesCutAtParagraphs() {
        val long = "a".repeat(400)
        // Ein Absatz wird angehängt, solange die Passage 700 Zeichen nicht übersteigt.
        assertEquals(listOf("x\ny\n$long", long), ChatRetrieval.pieces(listOf(" x ", "", "y", long, long)))
    }

    private fun notes() = listOf(
        Note(id = "A", title = "Budget", text = "Das Budget für das dritte Quartal steht fest.", createdAt = 1000),
        Note(id = "B", title = "Urlaub", text = "Urlaub im August an der Ostsee.", createdAt = 2000),
        Note(id = "C", title = "Team", createdAt = 3000)
            .withSpeakers(listOf(Speaker("s1", "Anna", 0)))
            .withSegments(listOf(TranscriptSegment(speakerId = "s1", start = 0.0, end = 2.0, text = "Wir planen die Budgets neu."))),
    )

    @Test fun bm25FindsWordsAndWordForms() {
        val chunks = ChatRetrieval.chunks(notes())
        assertTrue(chunks.any { it.text == "Transcript: Anna: Wir planen die Budgets neu." })
        val hits = ChatRetrieval.search("Budget", chunks)
        assertEquals(setOf("A", "C"), hits.map { it.noteID }.toSet())
        assertEquals("A", hits.first().noteID)
        assertTrue(ChatRetrieval.search("Ostsee", chunks).single().noteID == "B")
        assertTrue(ChatRetrieval.search("xyz", chunks).isEmpty())
    }

    @Test fun savedLinksAreFoundEvenWithoutAPage() {
        val links = listOf(
            Note(id = "L", title = "Kotlin Coroutines", url = "https://kotlinlang.org/docs/coroutines.html", createdAt = 1000),
            Note(id = "P", title = "Rezept", url = "https://example.com/risotto", pageText = "Risotto mit Pilzen und Parmesan.", summary = "Ein Pilzrisotto.", createdAt = 2000),
        )
        val chunks = ChatRetrieval.chunks(links)
        assertTrue(chunks.any { it.text == "Saved link (kotlinlang.org): https://kotlinlang.org/docs/coroutines.html" })
        assertEquals(setOf("L"), ChatRetrieval.search("kotlinlang", chunks).map { it.noteID }.toSet())
        assertEquals(setOf("P"), ChatRetrieval.search("Parmesan", chunks).map { it.noteID }.toSet())
        assertEquals(setOf("L", "P"), ChatRetrieval.search("saved links", chunks).map { it.noteID }.toSet())
    }

    @Test fun meaningAloneOnlyWhenItStandsOut() {
        fun chunk(id: String, text: String, v: FloatArray) = ChatChunk(id, id, 0, text, emptyMap(), emptyMap(), 5, v)
        val q = floatArrayOf(1f, 0f)
        val chunks = listOf(
            chunk("near", "a", floatArrayOf(1f, 0f)),
            chunk("x1", "b", floatArrayOf(0f, 1f)), chunk("x2", "c", floatArrayOf(0f, 1f)),
            chunk("x3", "d", floatArrayOf(0f, 1f)), chunk("x4", "e", floatArrayOf(0f, 1f)),
            chunk("x5", "f", floatArrayOf(0f, 1f)), chunk("x6", "g", floatArrayOf(0f, 1f)),
            chunk("x7", "h", floatArrayOf(0f, 1f)), chunk("x8", "i", floatArrayOf(0f, 1f)),
        )
        assertEquals(listOf("near"), ChatRetrieval.search("Ferien", chunks, q).map { it.noteID })
    }

    @Test fun recentNewestFirstWithinBudget() {
        val chunks = ChatRetrieval.chunks(notes())
        assertEquals("C", ChatRetrieval.recent(chunks).first().noteID)
    }

    @Test fun sourcesFromCitations() {
        val chunks = ChatRetrieval.chunks(notes()).sortedBy { it.noteID }
        assertEquals(listOf("B", "A"), ChatPrompt.sources("Siehe [2] und [1, 2], nicht [9].", chunks).map { it.noteID })
        assertEquals(listOf("A", "B", "C"), ChatPrompt.sources("Keine Zitate.", chunks).map { it.noteID })
    }
}

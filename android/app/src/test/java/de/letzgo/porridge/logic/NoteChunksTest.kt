package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.Speaker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteChunksTest {
    @Test fun tokensLikeNLTokenizer() {
        // Kleinbuchstaben, nur Wörter mit mindestens zwei Zeichen, keine Satzzeichen.
        // Erwartungen aus iOS (NLTokenizer, ausgeführt auf macOS 27).
        assertEquals(listOf("das", "budget", "für", "q3", "steht", "mail"), NoteChunks.tokens("Das Budget für Q3 steht: a, E-Mail!"))
        assertEquals(
            listOf("ich", "hab's", "3.5", "mio", "am", "12.10.2026", "um", "14", "30", "co", "op"),
            NoteChunks.tokens("Ich hab's 3.5 Mio. € am 12.10.2026 um 14:30 – co-op"),
        )
        assertEquals(listOf("grüße", "ça", "va", "tag", "foo", "bar", "2x"), NoteChunks.tokens("Grüße, ça va? #tag foo_bar 2x"))
    }

    @Test fun piecesCutAtParagraphs() {
        val long = "a".repeat(400)
        // Ein Absatz wird angehängt, solange die Passage 700 Zeichen nicht übersteigt.
        assertEquals(listOf("x\ny\n$long", long), NoteChunks.pieces(listOf(" x ", "", "y", long, long)))
    }

    private fun notes() = listOf(
        Note(id = "A", title = "Budget", text = "Das Budget für das dritte Quartal steht fest.", createdAt = 1000),
        Note(id = "B", title = "Urlaub", text = "Urlaub im August an der Ostsee.", createdAt = 2000),
        Note(id = "C", title = "Team", createdAt = 3000)
            .withSpeakers(listOf(Speaker("s1", "Anna", 0)))
            .withSegments(listOf(TranscriptSegment(speakerId = "s1", start = 0.0, end = 2.0, text = "Wir planen die Budgets neu."))),
    )

    /** Die Notizen, in denen jedes Wort vorkommt, wie der Index sie findet. */
    private fun found(query: String, chunks: List<NoteChunk>): Set<String> =
        NoteChunks.tokens(query).toSet().let { words ->
            chunks.groupBy { it.noteID }.filterValues { own -> words.all { w -> own.any { NoteChunks.frequency(w, it) > 0 } } }.keys
        }

    @Test fun findsWordsAndWordForms() {
        val chunks = NoteChunks.chunks(notes())
        assertTrue(chunks.any { it.text == "Transcript: Anna: Wir planen die Budgets neu." })
        assertEquals(setOf("A", "C"), found("Budget", chunks))
        assertEquals(setOf("B"), found("Ostsee", chunks))
        assertTrue(found("xyz", chunks).isEmpty())
    }

    @Test fun savedLinksAreFoundEvenWithoutAPage() {
        val links = listOf(
            Note(id = "L", title = "Kotlin Coroutines", url = "https://kotlinlang.org/docs/coroutines.html", createdAt = 1000),
            Note(id = "P", title = "Rezept", url = "https://example.com/risotto", pageText = "Risotto mit Pilzen und Parmesan.", summary = "Ein Pilzrisotto.", createdAt = 2000),
        )
        val chunks = NoteChunks.chunks(links)
        assertTrue(chunks.any { it.text == "Saved link (kotlinlang.org): https://kotlinlang.org/docs/coroutines.html" })
        assertEquals(setOf("L"), found("kotlinlang", chunks))
        assertEquals(setOf("P"), found("Parmesan", chunks))
        assertEquals(setOf("L", "P"), found("saved link", chunks))
    }
}

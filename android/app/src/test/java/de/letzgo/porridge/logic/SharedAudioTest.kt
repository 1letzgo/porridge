package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.TranscriptSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * iOS: `Note.isSaved`, `AutoSummary.kind` — eine aus einer anderen App geteilte Aufnahme zählt wie importiertes Audio
 * (Zusammenfassung von selbst, Aufgaben als To-do-Vorschläge); geteilte Links und Texte geben nie To-dos.
 */
class SharedAudioTest {
    private val page = "Wir planen den Launch, Anna schickt das Angebot bis Freitag. ".repeat(8)

    private val sharedAudio = Note(sourceRaw = NoteSource.SHARE.raw, audioFileName = "a.m4a")
        .withSegments(listOf(TranscriptSegment(start = 0.0, end = 60.0, text = page)))

    @Test fun sharedAudioIsImportedAudio() {
        assertFalse(sharedAudio.isSaved)
        assertFalse(sharedAudio.canBeTodo)
        assertEquals(AutoSummary.Kind.IMPORTED_AUDIO, AutoSummary.kind(sharedAudio))
        assertNotNull(TodoSuggestions.offered(sharedAudio).todoSuggestionsRaw)
    }

    @Test fun sharedTextAndLinksStillGiveNoToDos() {
        val text = Note(sourceRaw = NoteSource.SHARE.raw, text = page)
        assertTrue(text.isSaved)
        assertEquals(AutoSummary.Kind.SHARED_TEXT, AutoSummary.kind(text))
        assertNull(TodoSuggestions.offered(text).todoSuggestionsRaw)
        // Ein Link mit mitgeteiltem Text (ShareImport → LinkImport.add(text:)) bleibt ein Link.
        val link = Note(url = "https://example.com", sourceRaw = NoteSource.LINK.raw, text = "Schau dir das bis 2. Mai an")
        assertTrue(link.isSaved)
        assertNull(TodoSuggestions.offered(link).todoSuggestionsRaw)
    }
}

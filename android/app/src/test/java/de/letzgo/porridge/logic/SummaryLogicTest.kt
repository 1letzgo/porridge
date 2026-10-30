package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.TranscriptSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SummaryLogicTest {
    @Test fun detectsLanguageOrFallsBack() {
        assertEquals("de", LanguageDetect.detect("Wir haben heute über das Budget gesprochen und es ist noch nicht fertig, aber das wird schon."))
        assertEquals("en", LanguageDetect.detect("We talked about the budget and it is not done yet, but there will be a plan for that."))
        assertNull(LanguageDetect.detect("Budget Q3"))
        assertEquals("fr", SummaryLanguage.detect("x", "fr").code)
        assertEquals("en", SummaryLanguage.detect("x", "auto").code)
        assertEquals("German", SummaryLanguage("de").name)
        assertEquals("Aufgaben", SummaryLanguage("de").headings.actionItems)
    }

    @Test fun splitsAtLinesAndCutsEndlessOnes() {
        assertEquals(listOf("aa\nbb", "cc"), SummaryLogic.split("aa\nbb\ncc", size = 5))
        assertEquals(listOf("abcde", "fgh"), SummaryLogic.split("abcdefgh", size = 5))
    }

    @Test fun titleAndTagsComeOffTheAnswer() {
        val raw = "TITLE: **Budget Q3**\n\n## Zusammenfassung\nAlles gut.\n\nTAGS: Budget, #finanzen; budget, Q3 Plan"
        val note = SummaryLogic.apply(Note(), raw, "m", hasTranscript = true, now = 7)
        assertEquals("Budget Q3", note.title)
        assertEquals("## Zusammenfassung\nAlles gut.", note.summary)
        assertEquals(listOf("Budget", "finanzen", "Q3-Plan"), note.labels)
        assertEquals(7L, note.summarizedAt)
        val custom = SummaryLogic.apply(Note(title = "Mein", titleIsCustom = true, labels = listOf("x")), raw, "m", true)
        assertEquals("Mein", custom.title)
        assertEquals(listOf("x"), custom.labels)
    }

    @Test fun requestPicksMaterial() {
        val meeting = Note(text = "Eigene Notiz").withSegments(listOf(TranscriptSegment(start = 0.0, end = 1.0, text = "Hallo zusammen, wir sind heute hier und das ist gut.")))
        val r = SummaryLogic.request(meeting, "auto")
        assertTrue(r.hasTranscript && r.noun == "meeting")
        assertTrue(r.material.endsWith("Notes the user wrote down:\nEigene Notiz"))
        assertTrue(r.system.contains("TITLE:") && r.system.contains("German"))
        val empty = runCatching { SummaryLogic.request(Note(), "auto") }.exceptionOrNull()
        assertEquals("The note is empty.", empty?.message)
    }
}

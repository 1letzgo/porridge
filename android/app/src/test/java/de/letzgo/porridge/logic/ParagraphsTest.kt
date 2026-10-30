package de.letzgo.porridge.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class ParagraphsTest {
    @Test fun twoSentencesPerParagraph() {
        val (paragraphs, last) = Paragraphs.split("Eins ist gut. Zwei auch! Drei? Vier.")
        assertEquals(listOf("Eins ist gut. Zwei auch!", "Drei? Vier."), paragraphs)
        assertEquals(2, last)
        assertEquals("Eins ist gut. Zwei auch!\n\nDrei? Vier.", Paragraphs.format("Eins ist gut. Zwei auch! Drei? Vier."))
    }
}

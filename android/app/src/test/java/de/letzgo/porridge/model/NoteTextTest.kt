package de.letzgo.porridge.model

import org.junit.Assert.assertEquals
import org.junit.Test

class NoteTextTest {
    @Test fun tagsInOrderWithoutDuplicatesOrCode() {
        val text = "Plan #Projekt und #idee\n```\n#nicht\n```\nwieder #projekt, a#b, &#x; #über_2"
        assertEquals(listOf("Projekt", "idee", "über_2"), NoteText.tags(text))
    }

    @Test fun plainLinesStripMarks() {
        val text = "# Titel\n\n- [ ] **Aufgabe** eins\n1. Erstens\n> Zitat\n```\ncode\n"
        assertEquals(listOf("Titel", "Aufgabe eins", "Erstens", "Zitat", "code"), NoteText.plainLines(text))
    }

    @Test fun displayTitleFallbacks() {
        assertEquals("Empty Note", Note().displayTitle)
        assertEquals("example.org", Note(url = "https://www.example.org/x").displayTitle)
        assertEquals("Hallo Welt", Note(text = "## Hallo **Welt**\nmehr").displayTitle)
        assertEquals("mehr", Note(text = "## Hallo **Welt**\nmehr").preview)
    }

    @Test fun cleanTag() {
        assertEquals("zwei-worte", Note.cleanTag(" #zwei worte, "))
    }
}

package de.letzgo.porridge.logic

import de.letzgo.porridge.data.Me
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SummaryChecklistTest {
    private val summary = "## Aufgaben\n- [ ] Angebot schicken – Anna\n  - [x] Raum buchen\n1. [ ] Bericht\n- Ein Punkt"

    @Test fun togglesOnlyItsLine() {
        assertEquals("## Aufgaben\n- [x] Angebot schicken – Anna\n  - [x] Raum buchen\n1. [ ] Bericht\n- Ein Punkt", SummaryChecklist.toggled(summary, 1))
        assertEquals("## Aufgaben\n- [ ] Angebot schicken – Anna\n  - [ ] Raum buchen\n1. [ ] Bericht\n- Ein Punkt", SummaryChecklist.toggled(summary, 2))
        assertTrue("1. [x] Bericht" in SummaryChecklist.toggled(summary, 3).orEmpty())
    }

    @Test fun otherLinesStayAsTheyAre() {
        assertNull(SummaryChecklist.toggled(summary, 0))
        assertNull(SummaryChecklist.toggled(summary, 4))
        assertNull(SummaryChecklist.toggled(summary, 99))
        // Eine Klammer mitten im Text ist keine Checkbox.
        assertNull(SummaryChecklist.toggled("- siehe [ ] unten", 0))
    }

    @Test fun myNameMatchesWholeOrFirstName() {
        val names = Me.parseNames("Anna, Anna Berg")
        assertEquals(listOf("anna", "anna berg"), names)
        assertTrue(Me.isMe("Anna Berg", names))
        assertTrue(Me.isMe("anna", names))
        assertFalse(Me.isMe("Ben", names))
        assertFalse(Me.isMe(" ", names))
    }
}

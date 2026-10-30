package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionItemsLogicTest {
    private val summary = """
        # Weekly
        ## Zusammenfassung
        - Ein Punkt, keine Aufgabe
        ## Aufgaben
        - Angebot schicken – Anna
        - [x] Raum buchen
        1. Bericht schreiben
        - Keine weiteren Aufgaben.
        ## Entscheidungen
        - Wir nehmen Variante B
        ## Notizen
        - [ ] Checkbox irgendwo
    """.trimIndent()

    @Test fun parsesSectionsInAnyLanguage() {
        val parsed = ActionItemsLogic.parse(summary)
        assertEquals(
            listOf("Angebot schicken", "Raum buchen", "Bericht schreiben", "Wir nehmen Variante B", "Checkbox irgendwo"),
            parsed.map { it.text },
        )
        assertEquals("Anna", parsed[0].owner)
        assertTrue(parsed[1].done && parsed[1].isCheckbox)
        assertEquals(ActionItem.Kind.DECISION, parsed[3].kind)
    }

    @Test fun ownerOnlyForShortTail() {
        assertEquals("Text" to null, ActionItemsLogic.splitOwner("Text"))
        assertEquals("Plan - fertig" to "Ben", ActionItemsLogic.splitOwner("Plan - fertig – Ben"))
        assertEquals(ActionItemsLogic.splitOwner("A – das ist ein sehr langer Rest mit vielen Wörtern"), "A – das ist ein sehr langer Rest mit vielen Wörtern" to null)
    }

    @Test fun syncCreatesKeepsAndDeletes() {
        val note = Note(id = "N", summary = summary, summarizedAt = 5)
        val first = ActionItemsLogic.sync(note, emptyList(), now = 9)
        assertEquals(5, first.upserts.size)
        assertTrue(first.upserts.all { it.noteID == "N" && it.createdAt == 5L })
        val stored = first.upserts
        val again = ActionItemsLogic.sync(note, stored)
        assertTrue(again.isEmpty)
        val shorter = note.copy(summary = summary.replace("- Wir nehmen Variante B\n", ""))
        val plan = ActionItemsLogic.sync(shorter, stored)
        assertEquals(listOf("Wir nehmen Variante B"), plan.deletes.map { it.text })
        assertEquals(listOf(3), plan.upserts.map { it.order })
    }

    @Test fun tickingRewritesTheSummaryLine() {
        val items = ActionItemsLogic.sync(Note(id = "N", summary = summary), emptyList()).upserts
        val plain = items.first { it.text == "Angebot schicken" }
        val after = ActionItemsLogic.summaryAfterSetDone(summary, plain, true, items)
        assertTrue("- [x] Angebot schicken – Anna" in after)
        val box = items.first { it.text == "Raum buchen" }
        assertTrue("- [ ] Raum buchen" in ActionItemsLogic.summaryAfterSetDone(summary, box, false, items))
    }
}

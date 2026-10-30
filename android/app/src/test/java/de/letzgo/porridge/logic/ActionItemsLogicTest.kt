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

    @Test fun renamedTaskStillMatchesItsLine() {
        val note = Note(summary = summary)
        val items = ActionItemsLogic.sync(note, emptyList()).upserts
        assertTrue(items.all { it.summaryKey != null })
        val renamed = items.map { if (it.text == "Bericht schreiben") it.copy(text = "Quartalsbericht") else it }
        val plan = ActionItemsLogic.sync(note, renamed)
        assertTrue(plan.deletes.isEmpty())
        assertTrue(plan.upserts.none { it.text == "Bericht schreiben" })
    }

    @Test fun touchedTasksStayWhenTheirLineGoes() {
        val note = Note(summary = summary)
        val items = ActionItemsLogic.sync(note, emptyList()).upserts
            .map { if (it.text == "Bericht schreiben") it.copy(details = "Zahlen von Q3") else it }
        val plan = ActionItemsLogic.sync(note.copy(summary = "## Aufgaben\n- Angebot schicken – Anna"), items)
        val kept = plan.upserts.single { it.text == "Bericht schreiben" }
        assertEquals("kept", kept.source)
        assertTrue(plan.deletes.none { it.text == "Bericht schreiben" })
        assertTrue(plan.deletes.any { it.text == "Wir nehmen Variante B" })
    }

    @Test fun pagesNeverGiveTasks() {
        val page = Note(summary = summary, url = "https://example.com")
        assertTrue(ActionItemsLogic.sync(page, emptyList()).isEmpty)
        val items = ActionItemsLogic.sync(Note(id = page.id, summary = summary), emptyList()).upserts.map { it.copy(isDone = true) }
        assertEquals(items.size, ActionItemsLogic.sync(page, items).deletes.size)
    }

    @Test fun ownTasksShowInTheChatContext() {
        val own = ActionItem(text = "Steuer", details = "Belege sammeln", source = "manual")
        val block = ActionItemsLogic.contextBlock(listOf(own), emptyList(), 2000)
        assertTrue("- Steuer (task of its own" in block)
        assertTrue("Belege sammeln" in block)
    }

    @Test fun newTasksWaitForReview() {
        val note = Note(id = "N", summary = summary, summarizedAt = 5)
        val byText = ActionItemsLogic.sync(note, emptyList()).upserts.associateBy { it.text }
        assertTrue(byText.getValue("Angebot schicken").needsReview)
        // Already ticked in the summary, and decisions, need no review.
        assertEquals(ActionItem.Review.ACCEPTED, byText.getValue("Raum buchen").review)
        assertEquals(ActionItem.Review.ACCEPTED, byText.getValue("Wir nehmen Variante B").review)
        // Items from before the review count as accepted.
        assertEquals(ActionItem.Review.ACCEPTED, ActionItem().review)
    }

    @Test fun dismissedTasksStayHiddenAndAreNotMadeAgain() {
        val note = Note(id = "N", summary = summary, summarizedAt = 5)
        val stored = ActionItemsLogic.sync(note, emptyList()).upserts.map {
            if (it.text == "Angebot schicken") it.copy(reviewRaw = ActionItem.Review.DISMISSED.raw) else it
        }
        assertTrue(ActionItemsLogic.sync(note, stored).isEmpty)
        val block = ActionItemsLogic.contextBlock(stored, listOf(note), 4000)
        assertTrue("Angebot schicken" !in block)
        assertTrue("Bericht schreiben" in block)
    }
}

package de.letzgo.porridge.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SummaryTemplateTest {
    private val german = SummaryLanguage("de")

    @Test fun generalTemplateKeepsTheStandardSections() {
        val prompt = SummaryLogic.systemPrompt(german)
        assertTrue(prompt.contains("## Wichtige Punkte"))
        assertTrue(prompt.contains("## Entscheidungen"))
    }

    @Test fun templateReplacesTheMiddleSectionsButNotTasksAndTags() {
        val template = SummaryTemplate.BUILT_IN.first { it.id == "customer" }
        val prompt = SummaryLogic.systemPrompt(german, template)
        assertTrue(prompt.contains(template.focus))
        assertTrue(prompt.contains("## <\"Customer Needs\" in German>"))
        assertFalse(prompt.contains("## Wichtige Punkte"))
        assertTrue(prompt.contains("## Zusammenfassung"))
        assertTrue(prompt.contains("## Aufgaben"))
        assertTrue(prompt.contains("TITLE:"))
        assertTrue(prompt.contains("TAGS:"))
    }

    @Test fun taskLinesWithoutAListMarkGetOne() {
        assertEquals("Text\n- [ ] Anna ruft an\n- [ ] Tom schreibt\n- [x] Lisa", SummaryLogic.withListMarks("Text\n[ ] Anna ruft an\n- [ ] Tom schreibt\n[x] Lisa"))
    }

    @Test fun notesLookAtTheFocusToo() {
        assertTrue(SummaryLogic.notesPrompt(german, "meeting", "Note every price.").contains("Note every price."))
    }

    @Test fun partsNameTheHeaderAndRepeatTheEndOfThePreviousPart() {
        val material = (1..40).joinToString("\n") { "Line $it of the meeting" }
        val prompts = SummaryLogic.partPrompts(material, "Participants: Anna, Tom", 300)
        assertTrue(prompts.size > 1)
        assertTrue(prompts.all { it.startsWith("Participants: Anna, Tom") })
        assertFalse(prompts[0].contains("previous part"))
        assertTrue(prompts[1].contains("previous part"))
        for (number in 1..40) assertTrue(prompts.any { it.contains("Line $number of the meeting") })
        assertEquals("Line 1 of the meeting", material.lines().first())
    }
}

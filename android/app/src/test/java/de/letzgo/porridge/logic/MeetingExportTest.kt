package de.letzgo.porridge.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dieselben Fälle wie iOS: `MeetingExportTests`. */
class MeetingExportTest {
    private val lines = listOf(
        MeetingExport.Line("0:05", "Anna", "Wir beginnen mit dem Budget."),
        MeetingExport.Line("0:12", null, "Ohne Sprecher."),
    )
    private val summary = "## Key Points\n- **Budget** steht\n## Action Items\n- [ ] Angebot schicken\n- [x] Raum buchen\nEin Absatz."

    @Test fun textHasOnlyWhatWasChosen() {
        val onlySummary = MeetingExport("Weekly", "3. Nov", summary, emptyList()).plainText
        assertTrue(onlySummary.startsWith("Weekly\n\n3. Nov\n\nSummary\n\n"))
        assertTrue(onlySummary.contains("Key Points\n- Budget steht"))
        assertTrue(onlySummary.contains("- [ ] Angebot schicken"))
        assertFalse(onlySummary.contains("Transcript"))
        assertFalse(onlySummary.contains("#"))

        val onlyTranscript = MeetingExport("Weekly", "3. Nov", null, lines).plainText
        assertFalse(onlyTranscript.contains("Summary"))
        assertTrue(onlyTranscript.contains("[0:05] Anna: Wir beginnen mit dem Budget.\n[0:12] Ohne Sprecher."))
    }

    @Test fun fileNameDropsWhatFilesCannotHold() {
        assertEquals("Weekly   Budget", MeetingExport("Weekly / Budget", "", null, emptyList()).fileName)
        assertEquals("Meeting", MeetingExport("///", "", null, emptyList()).fileName)
    }
}

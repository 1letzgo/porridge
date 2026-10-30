package de.letzgo.porridge.cloud

import de.letzgo.porridge.logic.SummaryLanguage
import de.letzgo.porridge.logic.SummaryLogic
import de.letzgo.porridge.ml.TextModel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SummaryServiceTest {
    private class FakeModel : TextModel {
        val calls = mutableListOf<Pair<String, String>>()
        var uses = 0
        override val displayName = "Fake"
        override val isInstalled = true
        override suspend fun ensureReady(progress: (Float) -> Unit) = progress(1f)
        override suspend fun generate(system: String, user: String, maxTokens: Int): String {
            calls += system to user
            return "note ${calls.size}"
        }
        override fun beginUse() { uses++ }
        override fun endUse() { uses-- }
    }

    @Test fun longMaterialIsCondensedInParts() = runTest {
        val model = FakeModel()
        val long = (1..400).joinToString("\n") { "Zeile $it " + "x".repeat(60) }
        val request = SummaryLogic.Request("Date: x", long, SummaryLanguage("de"), "SYSTEM", "meeting", true)
        val steps = mutableListOf<String>()
        val result = SummaryService.summarizeLocally(model, request) { steps += it }
        assertTrue(model.calls.size >= 3)
        assertTrue(model.calls.dropLast(1).all { it.first.startsWith("You take notes on one part of a meeting transcript") })
        assertTrue(model.calls.last().second.contains("Notes on the meeting, in order:"))
        assertEquals("SYSTEM", model.calls.last().first)
        assertEquals("note ${model.calls.size}", result)
        assertTrue(steps.contains("Reading part 1 of 3 …"))
        assertEquals(0, model.uses)
    }
}

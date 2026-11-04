package de.letzgo.porridge.cloud

import de.letzgo.porridge.ml.LocalModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SummaryModelTest {
    @Test fun addedModelsSurviveStoring() {
        val models = listOf(SummaryModel.Cloud(AIProvider.ANTHROPIC, "a"), SummaryModel.Cloud(AIProvider.CUSTOM, "llama"))
        assertEquals(models, SummaryModel.decode(SummaryModel.encode(models)))
    }

    @Test fun anUnknownServiceFallsAwayAndDamagedTextIsNoList() {
        assertEquals(emptyList<SummaryModel>(), SummaryModel.decode("""[{"provider":"gone","model":"x"}]"""))
        assertNull(SummaryModel.decode("nonsense"))
    }

    @Test fun namesAreTheSameAsNextToAFinishedSummary() {
        assertEquals("Qwen3 4B (on-device)", SummaryModel.Local(LocalModel.QWEN3).label)
        assertEquals("Anthropic · x", SummaryModel.Cloud(AIProvider.ANTHROPIC, "x").label)
        assertEquals("Claude Haiku 5.5", SummaryModel.Cloud(AIProvider.ANTHROPIC, "claude-haiku-5-5").name)
        assertEquals("Claude Haiku 5.5 · Anthropic", SummaryModel.Cloud(AIProvider.ANTHROPIC, "claude-haiku-5-5").menuTitle)
    }
}

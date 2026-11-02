package de.letzgo.porridge.ml

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalLLMPromptTest {
    @Test fun gemmaPromptIsWhatTheModelsTemplateBuilds() {
        assertEquals(
            "<|turn>system\nBe brief.<turn|>\n<|turn>user\nHello<turn|>\n<|turn>model\n",
            LocalLLM.gemmaPrompt(" Be brief.\n", "Hello "),
        )
    }

    @Test fun thinkingIsRemoved() {
        assertEquals("Answer", LocalLLM.withoutThinking("<think>hm</think>\nAnswer"))
        assertEquals("Answer", LocalLLM.withoutThinking("<|channel>thought\nhm<channel|>Answer"))
        assertEquals("Answer", LocalLLM.withoutThinking("Answer<|channel>thought\nhm"))
    }

    @Test fun onlyNemotronBoltUsesGemmaTurns() {
        assertEquals(LocalModel.NEMOTRON_BOLT, LocalModel.of("nemotronBolt"))
        assertTrue(LocalModel.NEMOTRON_BOLT.gemmaTurns)
        assertFalse(LocalModel.NEMOTRON_BOLT.thinks)
        assertEquals(listOf(LocalModel.NEMOTRON_BOLT), LocalModel.entries.filter { it.gemmaTurns })
    }
}

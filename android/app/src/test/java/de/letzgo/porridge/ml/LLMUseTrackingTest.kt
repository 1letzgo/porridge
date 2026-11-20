package de.letzgo.porridge.ml

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Chat und Zusammenfassungen können verschiedene Modelle nutzen: Jedes wird für sich gezählt und freigegeben. */
class LLMUseTrackingTest {
    private fun pack(id: String) = ModelPack(id, id, emptyList())

    @Test fun anotherModelsUseDoesNotKeepTheFirstInMemory() {
        val a = pack("test-a-${System.nanoTime()}")
        val b = pack("test-b-${System.nanoTime()}")
        val released = CountDownLatch(2)
        val releasedA = AtomicInteger()
        val releasedB = AtomicInteger()

        ModelManager.beginLLMUse(a)
        ModelManager.endLLMUse(a) { releasedA.incrementAndGet(); released.countDown() }
        // Früher hob dies die Freigabe von A auf und ersetzte sie durch die von B: A blieb für immer geladen.
        ModelManager.beginLLMUse(b)
        ModelManager.endLLMUse(b) { releasedB.incrementAndGet(); released.countDown() }
        ModelManager.releaseIdleLLM()

        assertTrue(released.await(5, TimeUnit.SECONDS))
        assertEquals(1, releasedA.get())
        assertEquals(1, releasedB.get())
    }

    @Test fun aModelInUseIsNotReleasedButTheIdleOneIs() {
        val a = pack("test-a-${System.nanoTime()}")
        val b = pack("test-b-${System.nanoTime()}")
        val releasedA = CountDownLatch(1)
        val releasedB = AtomicInteger()

        ModelManager.beginLLMUse(a)
        ModelManager.endLLMUse(a) { releasedA.countDown() }
        ModelManager.beginLLMUse(b)
        assertEquals(1, ModelManager.llmUsers(b))
        assertEquals(0, ModelManager.llmUsers(a))
        ModelManager.releaseIdleLLM()

        assertTrue(releasedA.await(5, TimeUnit.SECONDS))
        // B wird noch genutzt; endet die Nutzung, wird es erst nach der Pause frei.
        ModelManager.endLLMUse(b) { releasedB.incrementAndGet() }
        assertEquals(0, ModelManager.llmUsers(b))
        assertEquals(0, releasedB.get())
    }

    @Test fun aNewUseCancelsOnlyItsOwnModelsRelease() {
        val a = pack("test-a-${System.nanoTime()}")
        val b = pack("test-b-${System.nanoTime()}")
        val releasedA = CountDownLatch(1)
        val releasedB = AtomicInteger()

        ModelManager.beginLLMUse(a)
        ModelManager.endLLMUse(a) { releasedA.countDown() }
        ModelManager.beginLLMUse(b)
        ModelManager.endLLMUse(b) { releasedB.incrementAndGet() }
        // B wird wieder genutzt, bevor die App in den Hintergrund geht: Nur A wird frei.
        ModelManager.beginLLMUse(b)
        ModelManager.releaseIdleLLM()

        assertTrue(releasedA.await(5, TimeUnit.SECONDS))
        assertFalse(releasedB.get() > 0)
        ModelManager.endLLMUse(b) { }
    }
}

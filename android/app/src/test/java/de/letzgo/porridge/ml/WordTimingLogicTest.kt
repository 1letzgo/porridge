package de.letzgo.porridge.ml

import org.junit.Assert.assertEquals
import org.junit.Test

class WordTimingLogicTest {
    @Test fun tokensBecomeWords() {
        val tokens = listOf("▁Hal", "lo", "▁Welt", ",", "▁wie", "▁geht's", "?")
        val starts = listOf(0.0f, 0.2f, 0.5f, 0.9f, 1.2f, 1.5f, 2.0f)
        val words = WordTimingLogic.words(tokens, starts, offset = 10.0)
        assertEquals(listOf("Hallo", "Welt,", "wie", "geht's?"), words.map { it.text })
        assertEquals(10.0, words[0].start, 1e-6)
        assertEquals(10.5, words[0].end, 1e-6)
        assertEquals(12.25, words.last().end, 1e-6)
    }

    @Test fun spaceMarkedTokensToo() {
        assertEquals(listOf("a", "bc"), WordTimingLogic.words(listOf(" a", " b", "c"), listOf(0f, 1f, 1.5f)).map { it.text })
    }

    @Test fun chunksCutAtQuietSpots() {
        val rate = 100
        // 60 s Ton, leise genau bei 22 s und 44 s.
        val samples = FloatArray(60 * rate) { i -> if (i in 2200..2204 || i in 4400..4404) 0f else 1f }
        val cuts = ChunkPlanner.cuts(samples, sampleRate = rate, maxSeconds = 25.0, searchSeconds = 5.0)
        assertEquals(3, cuts.size)
        assertEquals(0, cuts[0].first)
        assertEquals(cuts[0].last + 1, cuts[1].first)
        assertEquals(samples.size - 1, cuts.last().last)
        assert(cuts[0].last in 2195..2210) { "cut at ${cuts[0].last}" }
    }
}

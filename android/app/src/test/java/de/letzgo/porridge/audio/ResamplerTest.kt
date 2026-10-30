package de.letzgo.porridge.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class ResamplerTest {
    @Test fun downsamplesWithTheRightLengthAcrossBlocks() {
        val r = Resampler(48_000, 16_000)
        var total = 0
        repeat(10) { total += r.process(FloatArray(4801) { 0.5f }).size }
        assertEquals(16_003, total)
        // Konstanter Pegel bleibt konstant.
        assertEquals(0.5f, Resampler(44_100, 16_000).process(FloatArray(4410) { 0.5f }).drop(1).dropLast(1).maxOf { abs(it - 0.5f) } + 0.5f, 1e-4f)
    }

    @Test fun keepsLowToneAndDampsHighTone() {
        fun rms(x: FloatArray) = kotlin.math.sqrt(x.sumOf { (it * it).toDouble() } / x.size)
        val low = Resampler(48_000, 16_000).process(FloatArray(48_000) { sin(2 * PI * 440 * it / 48_000).toFloat() })
        val high = Resampler(48_000, 16_000).process(FloatArray(48_000) { sin(2 * PI * 15_000 * it / 48_000).toFloat() })
        assert(rms(low) > 0.65) { "low ${rms(low)}" }
        assert(rms(high) < 0.3) { "high ${rms(high)}" }
    }

    @Test fun upsamplesLinearly() {
        // Zwischen vorigem und aktuellem Sample interpoliert, also eine Eingabe-Sample verzögert.
        val out = Resampler(8_000, 16_000).process(floatArrayOf(0f, 1f, 0f))
        assertEquals(listOf(0f, 0f, 0f, 0.5f, 1f, 0.5f), out.toList())
    }
}

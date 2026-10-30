package de.letzgo.porridge.ml

import de.letzgo.porridge.model.Word
import kotlin.math.max
import kotlin.math.min

/**
 * iOS: `buildWordTimings` aus FluidAudio — aus den Token-Zeiten von Parakeet werden Wörter. Ein Token, das mit „▁“
 * oder einem Leerzeichen beginnt, beginnt ein Wort; andere hängen am vorigen (Wortteile, Satzzeichen).
 */
object WordTimingLogic {
    /** Länge des letzten Worts, wenn das Modell keine Dauer liefert. */
    private const val LAST_WORD_SECONDS = 0.25

    fun words(tokens: List<String>, starts: List<Float>, durations: List<Float> = emptyList(), offset: Double = 0.0): List<Word> {
        val result = mutableListOf<Word>()
        var text = StringBuilder()
        var start = 0.0
        var end = 0.0
        fun flush() {
            val word = text.toString().trim()
            if (word.isNotEmpty()) result += Word(word, offset + start, offset + max(end, start))
            text = StringBuilder()
        }
        for (i in tokens.indices) {
            val token = tokens[i]
            val t = starts.getOrNull(i)?.toDouble() ?: continue
            val tokenEnd = durations.getOrNull(i)?.takeIf { it > 0 }?.let { t + it } ?: starts.getOrNull(i + 1)?.toDouble() ?: (t + LAST_WORD_SECONDS)
            val beginsWord = token.startsWith("▁") || token.startsWith(" ")
            val clean = token.replace('▁', ' ')
            if (beginsWord || text.isEmpty()) {
                // Ein Satzzeichen ohne Wort davor beginnt keins.
                if (!beginsWord && clean.isNotBlank() && clean.none { it.isLetterOrDigit() } && result.isNotEmpty() && text.isEmpty()) {
                    val last = result.removeAt(result.lastIndex)
                    result += last.copy(text = last.text + clean.trim(), end = offset + tokenEnd)
                    continue
                }
                flush()
                start = t
            }
            text.append(clean)
            end = min(tokenEnd, starts.getOrNull(i + 1)?.toDouble() ?: tokenEnd).coerceAtLeast(t)
        }
        flush()
        return result
    }
}

/**
 * Schneidet lange Aufnahmen für die Erkennung in Abschnitte von höchstens [maxSeconds] Sekunden, an der leisesten
 * Stelle der letzten [searchSeconds] Sekunden eines Abschnitts (wie `RollingRecognizer` auf iOS), damit kein Wort
 * durchgeschnitten wird. FluidAudio tut das auf iOS intern; sherpa-onnx erwartet kurze Stücke.
 */
object ChunkPlanner {
    fun cuts(samples: FloatArray, sampleRate: Int = 16_000, maxSeconds: Double = 25.0, searchSeconds: Double = 5.0): List<IntRange> =
        cuts(samples.size, { samples[it] }, sampleRate, maxSeconds, searchSeconds)

    fun cuts(size: Int, sample: (Int) -> Float, sampleRate: Int = 16_000, maxSeconds: Double = 25.0, searchSeconds: Double = 5.0): List<IntRange> {
        val samples = object { val size = size; operator fun get(i: Int) = sample(i) }
        val max = (maxSeconds * sampleRate).toInt()
        val search = (searchSeconds * sampleRate).toInt()
        val frame = sampleRate / 20 // 50 ms
        val result = mutableListOf<IntRange>()
        var start = 0
        while (samples.size - start > max) {
            val from = start + max - search
            var bestAt = start + max
            var bestEnergy = Double.MAX_VALUE
            var f = from
            while (f + frame <= start + max) {
                var energy = 0.0
                for (i in f until f + frame) energy += samples[i] * samples[i]
                if (energy < bestEnergy) { bestEnergy = energy; bestAt = f + frame / 2 }
                f += frame
            }
            result += start until bestAt
            start = bestAt
        }
        if (start < samples.size) result += start until samples.size
        return result
    }
}

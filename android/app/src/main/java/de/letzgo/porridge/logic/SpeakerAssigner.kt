package de.letzgo.porridge.logic

import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.Word
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/** iOS: `ChannelEnergy` (Services/AudioPreprocessor.swift) — Energie je Kanal in Rahmen von `frameDuration` Sekunden. */
class ChannelEnergy(val frameDuration: Double, val left: FloatArray, val right: FloatArray)

/** iOS: `DiarizedSegment`. */
data class DiarizedSegment(val speaker: String, val start: Double, val end: Double)

/** iOS: `SpeakerAssigner` (Services/SpeakerAssigner.swift). */
object SpeakerAssigner {
    const val LEFT_CHANNEL_ID = "ch0"
    const val RIGHT_CHANNEL_ID = "ch1"

    /**
     * Ordnet jedes Wort dem lauteren Mikrofon zu. Beide Kanäle werden zuerst auf ihren typischen Sprachpegel
     * normiert, damit unterschiedliche Verstärkung der Sender die Entscheidung nicht verschiebt; Übersprechen
     * ist immer viel leiser als die eigene Stimme.
     */
    fun byChannel(words: List<Word>, energy: ChannelEnergy): List<String> {
        val count = min(energy.left.size, energy.right.size)
        if (count == 0) return words.map { LEFT_CHANNEL_ID }
        val leftRef = percentile(energy.left, 0.9)
        val rightRef = percentile(energy.right, 0.9)
        val eps = 1e-10f

        val result = mutableListOf<String>()
        var previous: String? = null
        for (word in words) {
            val a = min(count - 1, max(0, (word.start / energy.frameDuration).toInt()))
            val b = min(count - 1, max(a, ceil(word.end / energy.frameDuration).toInt()))
            var l = 0f
            var r = 0f
            for (i in a..b) {
                l += energy.left[i]
                r += energy.right[i]
            }
            val db = 10 * log10((l / max(leftRef, eps) + eps) / (r / max(rightRef, eps) + eps))
            val id = if (abs(db) < 2 && previous != null) previous else if (db >= 0) LEFT_CHANNEL_ID else RIGHT_CHANNEL_ID
            result += id
            previous = id
        }
        return smoothIslands(result, words)
    }

    /** Legt Diarisierungs-Abschnitte auf Wörter. Gibt stabile Kennungen („s1“, „s2“ …) in Reihenfolge des Auftretens. */
    fun byDiarization(words: List<Word>, segments: List<DiarizedSegment>): Pair<List<String?>, List<String>> {
        if (segments.isEmpty()) return words.map { null } to emptyList()
        val mapping = HashMap<String, String>()
        val order = mutableListOf<String>()
        val ids: List<String?> = words.map { word ->
            val mid = (word.start + word.end) / 2
            val match = segments.firstOrNull { mid >= it.start && mid <= it.end } ?: segments.minByOrNull { distance(mid, it) }
            val raw = match?.speaker ?: return@map null
            mapping[raw] ?: "s${order.size + 1}".also { mapping[raw] = it; order += it }
        }
        val smoothed = smoothIslands(ids.map { it ?: "" }, words).map { it.ifEmpty { null } }
        return smoothed to order
    }

    /** Fasst aufeinanderfolgende Wörter desselben Sprechers zu lesbaren Abschnitten zusammen. */
    fun group(words: List<Word>, speakerIds: List<String?>): List<TranscriptSegment> {
        val segments = mutableListOf<TranscriptSegment>()
        var current: TranscriptSegment? = null
        words.forEachIndexed { index, word ->
            val speaker = speakerIds.getOrNull(index)
            val segment = current
            current = if (segment != null && segment.speakerId == speaker && word.start - segment.end < 2.0 &&
                !(segment.end - segment.start > 45 && endsSentence(segment.text))
            ) {
                segment.copy(text = segment.text + " " + word.text, end = word.end)
            } else {
                segment?.let { segments += it }
                TranscriptSegment(speakerId = speaker, start = word.start, end = word.end, text = word.text)
            }
        }
        current?.let { segments += it }
        return segments
    }

    /** Dreht einzelne kurze Wörter, die denselben Sprecher unterbrechen (A B A → A A A). */
    private fun smoothIslands(ids: List<String>, words: List<Word>): List<String> {
        if (ids.size < 3) return ids
        val out = ids.toMutableList()
        for (i in 1 until ids.size - 1) {
            if (ids[i - 1] == ids[i + 1] && ids[i] != ids[i - 1] && words[i].end - words[i].start < 0.6) out[i] = ids[i - 1]
        }
        return out
    }

    private fun distance(t: Double, segment: DiarizedSegment) = if (t < segment.start) segment.start - t else max(0.0, t - segment.end)

    private fun endsSentence(text: String) = text.lastOrNull()?.let { it in ".?!" } ?: false

    private fun percentile(values: FloatArray, p: Double): Float {
        if (values.isEmpty()) return 1f
        val sorted = values.sorted()
        return sorted[min(sorted.size - 1, ((sorted.size - 1) * p).toInt())]
    }
}

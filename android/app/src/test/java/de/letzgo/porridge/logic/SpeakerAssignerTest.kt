package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Word
import org.junit.Assert.assertEquals
import org.junit.Test

class SpeakerAssignerTest {
    private fun words(vararg spans: Pair<Double, Double>) = spans.mapIndexed { i, (s, e) -> Word("w$i", s, e) }

    @Test fun louderNormalizedChannelWins() {
        // Links 10 Rahmen laut, dann rechts; rechts mit halber Verstärkung (Normierung gleicht aus).
        val left = FloatArray(20) { if (it < 10) 1f else 0.01f }
        val right = FloatArray(20) { if (it < 10) 0.005f else 0.5f }
        val energy = ChannelEnergy(0.05, left, right)
        val ids = SpeakerAssigner.byChannel(words(0.0 to 0.2, 0.25 to 0.45, 0.6 to 0.9), energy)
        assertEquals(listOf("ch0", "ch0", "ch1"), ids)
    }

    @Test fun diarizationIdsInOrderAndIslandsSmoothed() {
        val segments = listOf(DiarizedSegment("B", 0.0, 1.0), DiarizedSegment("A", 1.0, 1.3), DiarizedSegment("B", 1.3, 3.0), DiarizedSegment("A", 3.0, 5.0))
        val (ids, order) = SpeakerAssigner.byDiarization(words(0.1 to 0.5, 1.05 to 1.25, 1.5 to 2.2, 3.5 to 4.0, 6.0 to 6.5), segments)
        // Das kurze Wort bei 1.1 s wird geglättet (A B A); das Wort nach dem letzten Abschnitt geht an den nächsten.
        assertEquals(listOf("s1", "s1", "s1", "s2", "s2"), ids)
        assertEquals(listOf("s1", "s2"), order)
    }

    @Test fun groupSplitsOnSpeakerAndPauses() {
        val w = listOf(Word("Hallo", 0.0, 0.4), Word("du.", 0.5, 0.8), Word("Ja", 1.0, 1.2), Word("später", 4.0, 4.5))
        val segments = SpeakerAssigner.group(w, listOf("a", "a", "b", "b"))
        assertEquals(listOf("Hallo du.", "Ja", "später"), segments.map { it.text })
        assertEquals(0.8, segments[0].end, 1e-9)
    }
}

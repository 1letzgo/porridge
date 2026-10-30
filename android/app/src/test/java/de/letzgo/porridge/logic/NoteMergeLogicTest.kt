package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.TranscriptSegment
import org.junit.Assert.assertEquals
import org.junit.Test

class NoteMergeLogicTest {
    @Test fun mergesSpeakersAndShiftsSegments() {
        val a = Note(id = "A", text = "eins", createdAt = 1, duration = 10.0)
            .withSpeakers(listOf(Speaker("s1", "Anna", 0), Speaker("s2", "Speaker 2", 1)))
            .withSegments(listOf(TranscriptSegment(speakerId = "s1", start = 1.0, end = 2.0, text = "Hallo"), TranscriptSegment(speakerId = "s2", start = 3.0, end = 4.0, text = "Ja")))
        val b = Note(id = "B", text = "zwei", createdAt = 2, duration = 5.0, summary = "alt")
            .withSpeakers(listOf(Speaker("s1", "anna", 0), Speaker("s2", "Speaker 1", 1)))
            .withSegments(listOf(TranscriptSegment(speakerId = "s1", start = 0.5, end = 1.0, text = "Weiter"), TranscriptSegment(speakerId = "s2", start = 2.0, end = 3.0, text = "Gut")))
        val ordered = listOf(a, b)
        val (offsets, total) = NoteMergeLogic.offsetsWithoutAudio(ordered)
        assertEquals(listOf(0.0, 10.0), offsets)
        val merged = NoteMergeLogic.merge(b, ordered, offsets, total, null, null, now = 9)
        assertEquals(listOf("Anna", "Speaker 1", "Speaker 2"), merged.speakers.map { it.name })
        assertEquals(listOf("m1", "m2", "m1", "m3"), merged.segments.map { it.speakerId })
        assertEquals(10.5, merged.segments[2].start, 1e-9)
        assertEquals("eins\n\nzwei", merged.text)
        assertEquals(1L, merged.createdAt)
        assertEquals(null, merged.summary)
        assertEquals("diarized", merged.speakerModeRaw)
    }
}

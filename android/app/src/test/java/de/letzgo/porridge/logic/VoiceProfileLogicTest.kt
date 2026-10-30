package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.VoiceMath
import de.letzgo.porridge.model.VoiceProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VoiceProfileLogicTest {
    private fun speaker(id: String, name: String, voice: FloatArray, seconds: Double = 10.0) =
        Speaker(id, name, 0, voice = VoiceProfileLogic.encode(voice), voiceSeconds = seconds)

    private val anna = VoiceProfile(id = "P1", name = "Anna", voiceData = VoiceMath.data(floatArrayOf(1f, 0f, 0f)), seconds = 30.0)
    private val ben = VoiceProfile(id = "P2", name = "Ben", voiceData = VoiceMath.data(floatArrayOf(0f, 1f, 0f)), seconds = 30.0)

    @Test fun clearMatchesAreNamedOncePerMeeting() {
        val speakers = listOf(
            speaker("s1", "Speaker 1", floatArrayOf(0.95f, 0.1f, 0f)),
            speaker("s2", "Speaker 2", floatArrayOf(0.9f, 0.2f, 0f)),
            speaker("s3", "Speaker 3", floatArrayOf(0.5f, 0.5f, 0.7f)),
            speaker("s4", "Speaker 4", floatArrayOf(0f, 1f, 0f), seconds = 2.0),
        )
        val result = VoiceProfileLogic.match(speakers, listOf(anna, ben), refine = true, now = 5)
        assertEquals(listOf("Anna", "Speaker 2", "Speaker 3", "Speaker 4"), result.speakers.map { it.name })
        assertEquals("P1", result.speakers[0].profileID)
        assertEquals(listOf("P1"), result.refined.map { it.id })
        assertEquals(40.0, result.refined[0].seconds, 1e-9)
    }

    @Test fun teachingCreatesOrRefines() {
        val (s, created) = VoiceProfileLogic.teach(speaker("s1", "Clara", floatArrayOf(0f, 0f, 1f)), listOf(anna))
        assertEquals(created!!.id, s.profileID)
        val (s2, refined) = VoiceProfileLogic.teach(speaker("s1", "anna", floatArrayOf(0.9f, 0.1f, 0f)), listOf(anna))
        assertEquals("P1", s2.profileID)
        assertEquals("P1", refined!!.id)
        val (_, ignored) = VoiceProfileLogic.teach(speaker("s1", "Anna", floatArrayOf(0f, 1f, 0f)), listOf(anna))
        assertNull(ignored)
    }
}

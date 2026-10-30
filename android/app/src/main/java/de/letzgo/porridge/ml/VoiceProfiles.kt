package de.letzgo.porridge.ml

import de.letzgo.porridge.data.Me

import de.letzgo.porridge.logic.VoiceProfileLogic
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.VoiceProfile
import de.letzgo.porridge.store.PorridgeDatabase

/**
 * iOS: `VoiceProfiles` (Services/VoiceProfiles.swift) — Personen über ihre Stimme wiedererkennen. Die Logik liegt in
 * [VoiceProfileLogic]; hier Stimmabdrücke berechnen und Profile speichern.
 */
class VoiceProfiles(private val db: PorridgeDatabase = PorridgeDatabase.shared) {
    /** Gibt jedem Sprecher einen Stimmabdruck und benennt die, die zu einer bekannten Person passen. */
    suspend fun identify(speakers: List<Speaker>, segments: List<TranscriptSegment>, samples: FloatArray): List<Speaker> {
        if (speakers.isEmpty()) return speakers
        runCatching { Diarizer.ensure() }.onFailure { return speakers }
        var result = speakers.map { speaker ->
            val spans = VoiceProfileLogic.spans(speaker.id, segments)
            val seconds = spans.sumOf { it.endInclusive - it.start }
            if (seconds < 3) return@map speaker
            val print = VoiceProfileLogic.fingerprint(runCatching { Diarizer.embed(samples, spans) }.getOrDefault(emptyList())) ?: return@map speaker
            speaker.copy(voice = VoiceProfileLogic.encode(print), voiceSeconds = seconds)
        }
        // Schon beim Aufnehmen benannte Sprecher (die zwei DJI-Mikrofone) lernen ihre Stimme gleich.
        result = result.map { speaker ->
            if (speaker.profileID == null && !VoiceProfileLogic.isDefaultName(speaker.name)) teach(speaker) else speaker
        }
        val matched = VoiceProfileLogic.match(result, db.voiceProfiles().all(), refine = true)
        db.voiceProfiles().upsertAll(matched.refined)
        return matched.speakers
    }

    private suspend fun teach(speaker: Speaker): Speaker {
        val (taught, profile) = VoiceProfileLogic.teach(speaker, db.voiceProfiles().all())
        profile?.let { db.voiceProfiles().upsert(it) }
        return taught
    }

    /** Benennt einen Sprecher um und lernt die Stimme unter diesem Namen. Danach [rematchAllMeetings]. */
    suspend fun rename(speakerID: String, name: String, speakers: List<Speaker>): List<Speaker> =
        speakers.map { if (it.id != speakerID) it else it.copy(name = name).let { s -> if (s.voice != null) teach(s) else s } }

    /** Benennt frühere Sprecher mit Standardnamen nach dem, was jetzt bekannt ist. */
    suspend fun rematchAllMeetings() {
        val profiles = db.voiceProfiles().all()
        if (profiles.isEmpty()) return
        for (note in db.notes().all()) {
            val before = note.speakers
            if (before.isEmpty()) continue
            val after = VoiceProfileLogic.match(before, profiles, refine = false).speakers
            if (after != before) db.notes().upsert(note.withSpeakers(after))
        }
    }

    /** Benennt eine Person überall um. */
    suspend fun rename(profile: VoiceProfile, name: String) {
        db.voiceProfiles().upsert(profile.copy(name = name, updatedAt = System.currentTimeMillis()))
        if (Me.voiceID == profile.id) Me.setVoice(profile.copy(name = name))
        for (note in db.notes().all()) {
            val speakers = note.speakers
            if (speakers.none { it.profileID == profile.id }) continue
            db.notes().upsert(note.withSpeakers(speakers.map { if (it.profileID == profile.id) it.copy(name = name) else it }))
        }
    }

    /** Vergisst die Stimme einer Person; schon vergebene Namen bleiben. */
    suspend fun delete(profile: VoiceProfile) {
        if (Me.voiceID == profile.id) Me.setVoice(null)
        for (note in db.notes().all()) {
            val speakers = note.speakers
            if (speakers.none { it.profileID == profile.id }) continue
            db.notes().upsert(note.withSpeakers(speakers.map { if (it.profileID == profile.id) it.copy(profileID = null) else it }))
        }
        db.voiceProfiles().delete(profile)
    }
}

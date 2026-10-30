package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.VoiceMath
import java.util.Base64
import kotlin.math.max
import kotlin.math.sqrt

/**
 * iOS: der reine Teil von `NoteMerger` (Services/NoteMerger.swift) — mehrere aufgenommene Notizen werden eine:
 * Transkripte in zeitlicher Reihenfolge, gleiche Personen ein Sprecher. Das Zusammenfügen der Audiodateien und
 * das Löschen der anderen Notizen macht `store/NoteMerger.kt`.
 */
object NoteMergeLogic {
    private const val DEFAULT_NAME_PREFIX = "Speaker "
    /** iOS: `VoiceProfiles.matchThreshold`. */
    const val VOICE_MATCH_THRESHOLD = 0.60f

    /** Start jeder Notiz auf der gemeinsamen Zeitachse, wenn es kein zusammengefügtes Audio gibt. */
    fun offsetsWithoutAudio(ordered: List<Note>): Pair<List<Double>, Double> {
        val offsets = mutableListOf<Double>()
        var total = 0.0
        for (meeting in ordered) {
            offsets += total
            total += max(meeting.duration, meeting.segments.lastOrNull()?.end ?: 0.0)
        }
        return offsets to total
    }

    /**
     * Das Ergebnis für [base]: `ordered` sind alle Notizen nach `createdAt`, [offsets] ihre Startzeiten,
     * [total] die Gesamtdauer, [mergedAudio]/[channelCount] die neue Aufnahme (oder null).
     */
    fun merge(
        base: Note,
        ordered: List<Note>,
        offsets: List<Double>,
        total: Double,
        mergedAudio: String?,
        channelCount: Int?,
        now: Long = System.currentTimeMillis(),
    ): Note {
        val speakers = mutableListOf<Speaker>()
        val segments = mutableListOf<TranscriptSegment>()
        ordered.forEachIndexed { index, meeting ->
            val idMap = HashMap<String, String>()
            for (speaker in meeting.speakers) {
                val match = speakers.indexOfFirst { isSamePerson(it, speaker) }
                if (match >= 0) {
                    idMap[speaker.id] = speakers[match].id
                    var merged = speakers[match]
                    if (merged.voice == null) merged = merged.copy(voice = speaker.voice, voiceSeconds = speaker.voiceSeconds)
                    if (merged.profileID == null) merged = merged.copy(profileID = speaker.profileID)
                    speakers[match] = merged
                } else {
                    val copy = speaker.copy(id = "m${speakers.size + 1}", colorIndex = speakers.size)
                    speakers += copy
                    idMap[speaker.id] = copy.id
                }
            }
            for (segment in meeting.segments) {
                segments += segment.copy(
                    start = segment.start + offsets[index],
                    end = segment.end + offsets[index],
                    speakerId = segment.speakerId?.let { idMap[it] },
                )
            }
        }
        // Mehrere unbenannte Sprecher aus verschiedenen Meetings hießen sonst alle „Speaker 1“.
        var number = 1
        speakers.indices.forEach { i ->
            if (speakers[i].name.startsWith(DEFAULT_NAME_PREFIX) && speakers[i].profileID == null) {
                speakers[i] = speakers[i].copy(name = "$DEFAULT_NAME_PREFIX$number")
                number++
            }
        }
        return base.copy(
            audioFileName = mergedAudio,
            channelCount = channelCount ?: base.channelCount,
            createdAt = ordered.first().createdAt,
            // Auch die eigenen Texte in zeitlicher Reihenfolge.
            text = ordered.map { it.text }.filter { it.isNotEmpty() }.joinToString("\n\n"),
            updatedAt = now,
            duration = total,
            speakerModeRaw = (if (speakers.isEmpty()) SpeakerMode.NONE else SpeakerMode.DIARIZED).raw,
            summary = null,
            summaryModel = null,
            summarizedAt = null,
            errorMessage = null,
            statusRaw = ProcessingStatus.READY.raw,
        ).withSegments(segments).withSpeakers(speakers)
    }

    private fun isSamePerson(a: Speaker, b: Speaker): Boolean {
        if (a.profileID != null && b.profileID != null) return a.profileID == b.profileID
        val aNamed = !a.name.startsWith(DEFAULT_NAME_PREFIX)
        val bNamed = !b.name.startsWith(DEFAULT_NAME_PREFIX)
        if (aNamed && bNamed) return a.name.equals(b.name, ignoreCase = true)
        // Mindestens einer ist unbenannt: Stimmen vergleichen.
        val va = a.voice ?: return false
        val vb = b.voice ?: return false
        return cosine(VoiceMath.floats(Base64.getDecoder().decode(va)), VoiceMath.floats(Base64.getDecoder().decode(vb))) >= VOICE_MATCH_THRESHOLD
    }

    /** iOS: `VoiceMath.cosine`. */
    fun cosine(a: FloatArray, b: FloatArray): Float {
        if (a.size != b.size || a.isEmpty()) return 0f
        var dot = 0f
        var na = 0f
        var nb = 0f
        for (i in a.indices) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        val norm = sqrt(na) * sqrt(nb)
        return if (norm > 0) dot / norm else 0f
    }
}

package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.model.VoiceMath
import de.letzgo.porridge.model.VoiceProfile
import java.util.Base64
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * iOS: die reine Logik von `VoiceProfiles` und `VoiceMath` (Services/VoiceProfiles.swift) — Personen über ihre
 * Stimme in mehreren Meetings wiedererkennen. Speichern macht `ml/VoiceProfiles.kt`.
 */
object VoiceProfileLogic {
    /** Kosinus, ab dem zwei Stimmen dieselbe Person sind. */
    const val MATCH_THRESHOLD = 0.60f
    /** Das beste Profil muss das zweitbeste um so viel schlagen. */
    const val MARGIN = 0.06f
    /** So gute Treffer verfeinern das Profil auch. */
    const val REFINE_THRESHOLD = 0.72f
    /** So viel Sprache braucht ein Sprecher, bevor einem Treffer getraut wird. */
    const val MIN_SECONDS = 4.0
    private const val DEFAULT_NAME_PREFIX = "Speaker "

    fun normalized(v: FloatArray): FloatArray {
        val norm = sqrt(v.fold(0f) { acc, x -> acc + x * x })
        return if (norm > 0) FloatArray(v.size) { v[it] / norm } else v
    }

    fun blend(a: FloatArray, wa: Double, b: FloatArray, wb: Double): FloatArray {
        if (a.size != b.size) return b
        val total = max(wa + wb, 0.001)
        return normalized(FloatArray(a.size) { ((a[it] * wa + b[it] * wb) / total).toFloat() })
    }

    fun encode(voice: FloatArray): String = Base64.getEncoder().encodeToString(VoiceMath.data(voice))
    fun decode(voice: String): FloatArray = VoiceMath.floats(Base64.getDecoder().decode(voice))

    /** Die Zeitspannen, aus denen der Stimmabdruck eines Sprechers entsteht: seine längsten Beiträge, zusammen höchstens 60 s. */
    fun spans(speakerID: String, segments: List<TranscriptSegment>): List<ClosedFloatingPointRange<Double>> {
        val turns = segments.filter { it.speakerId == speakerID && it.end - it.start >= 1.5 }.sortedByDescending { it.end - it.start }
        val spans = mutableListOf<ClosedFloatingPointRange<Double>>()
        var seconds = 0.0
        for (turn in turns) {
            if (spans.size >= 8 || seconds >= 60) break
            val length = min(turn.end - turn.start, 12.0)
            spans += turn.start..(turn.start + length)
            seconds += length
        }
        return spans
    }

    /** Ein Abdruck aus mehreren Einbettungen: normiert, summiert, wieder normiert. */
    fun fingerprint(embeddings: List<FloatArray>): FloatArray? {
        if (embeddings.isEmpty()) return null
        val normalized = embeddings.map(::normalized)
        val sum = FloatArray(normalized[0].size)
        for (v in normalized) if (v.size == sum.size) for (i in sum.indices) sum[i] += v[i]
        return normalized(sum)
    }

    /** Ergebnis von [match]: die Sprecher und die Profile, die dabei verfeinert wurden. */
    data class MatchResult(val speakers: List<Speaker>, val refined: List<VoiceProfile>)

    /** Benennt Sprecher mit Standardnamen, wenn ein Profil klar passt; jede Person nur einmal je Meeting. */
    fun match(speakers: List<Speaker>, profiles: List<VoiceProfile>, refine: Boolean, now: Long = System.currentTimeMillis()): MatchResult {
        if (profiles.isEmpty()) return MatchResult(speakers, emptyList())
        data class Candidate(val speaker: Int, val profile: VoiceProfile, val score: Float, val runnerUp: Float)
        val candidates = mutableListOf<Candidate>()
        speakers.forEachIndexed { index, speaker ->
            val data = speaker.voice
            if (speaker.profileID != null || !speaker.name.startsWith(DEFAULT_NAME_PREFIX) || data == null || (speaker.voiceSeconds ?: 0.0) < MIN_SECONDS) return@forEachIndexed
            val voice = decode(data)
            val scored = profiles.map { it to NoteMergeLogic.cosine(voice, it.voice) }.sortedByDescending { it.second }
            val best = scored.first()
            candidates += Candidate(index, best.first, best.second, scored.getOrNull(1)?.second ?: -1f)
        }
        val result = speakers.toMutableList()
        val refined = LinkedHashMap<String, VoiceProfile>()
        val taken = HashSet<String>()
        for (c in candidates.sortedByDescending { it.score }) {
            if (c.score < MATCH_THRESHOLD || c.score - c.runnerUp < MARGIN || c.profile.id in taken) continue
            taken += c.profile.id
            result[c.speaker] = result[c.speaker].copy(name = c.profile.name, profileID = c.profile.id)
            val voice = result[c.speaker].voice
            if (refine && c.score >= REFINE_THRESHOLD && voice != null) {
                val current = refined[c.profile.id] ?: c.profile
                refined[c.profile.id] = absorb(decode(voice), result[c.speaker].voiceSeconds ?: 0.0, current, now)
            }
        }
        return MatchResult(result, refined.values.toList())
    }

    fun absorb(voice: FloatArray, seconds: Double, profile: VoiceProfile, now: Long = System.currentTimeMillis()): VoiceProfile =
        profile.copy(
            voiceData = VoiceMath.data(blend(profile.voice, min(profile.seconds, 120.0), voice, seconds)),
            seconds = min(profile.seconds + seconds, 300.0),
            updatedAt = now,
        )

    /**
     * Legt die Stimme eines benannten Sprechers unter seinem Namen ab: verfeinert das Profil der Person oder legt
     * es an. Liefert den Sprecher (mit `profileID`) und das neue oder geänderte Profil (oder null).
     */
    fun teach(speaker: Speaker, profiles: List<VoiceProfile>, now: Long = System.currentTimeMillis()): Pair<Speaker, VoiceProfile?> {
        val data = speaker.voice ?: return speaker to null
        val voice = decode(data)
        val seconds = speaker.voiceSeconds ?: 0.0
        val profile = profiles.firstOrNull { it.name.equals(speaker.name, ignoreCase = true) }
        if (profile != null) {
            // Dieselbe Person ist schon bekannt: die Stimme nur hinzunehmen, wenn sie wirklich ihre ist.
            val changed = if (speaker.profileID == profile.id || NoteMergeLogic.cosine(voice, profile.voice) >= 0.45f) absorb(voice, seconds, profile, now) else null
            return speaker.copy(profileID = profile.id) to changed
        }
        val created = VoiceProfile(name = speaker.name, voiceData = VoiceMath.data(voice), seconds = seconds, updatedAt = now)
        return speaker.copy(profileID = created.id) to created
    }

    fun isDefaultName(name: String) = name.startsWith(DEFAULT_NAME_PREFIX)
}

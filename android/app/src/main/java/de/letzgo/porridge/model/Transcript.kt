package de.letzgo.porridge.model

import kotlinx.serialization.Serializable
import java.util.UUID

/** iOS: `Speaker` (Models/Transcript.swift). `voice` ist wie dort Float32-Bytes, im JSON als Base64. */
@Serializable
data class Speaker(
    val id: String,
    val name: String,
    val colorIndex: Int,
    val voice: String? = null,
    val voiceSeconds: Double? = null,
    val profileID: String? = null,
)

/** iOS: `TranscriptSegment`. */
@Serializable
data class TranscriptSegment(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val speakerId: String? = null,
    val start: Double,
    val end: Double,
    val text: String,
)

/** iOS: `Word` — ein erkanntes Wort mit Zeit, unabhängig von der Erkennungs-Bibliothek. */
data class Word(val text: String, val start: Double, val end: Double)

/** iOS: `ProcessingStatus`. */
enum class ProcessingStatus(val raw: String) {
    RECORDED("recorded"),
    TRANSCRIBING("transcribing"),
    READY("ready"),
    FAILED("failed");

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: READY
    }
}

/** iOS: `SpeakerMode`. */
enum class SpeakerMode(val raw: String) {
    /** Keine Sprechertrennung. */
    NONE("none"),
    /** Jeder Kanal gehört einem Sprecher (z. B. DJI Mic im Stereo-Modus). */
    CHANNELS("channels"),
    /** Sprecher per Diarisierung aus einem Kanal erkannt. */
    DIARIZED("diarized");

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: NONE
    }
}

/** iOS: `TimeInterval.clockString` — „1:02:03“ bzw. „2:03“. */
val Double.clockString: String
    get() {
        val total = toLong()
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

/** iOS: `TimeInterval.durationText`. */
val Double.durationText: String
    get() {
        val minutes = Math.round(this / 60).toInt()
        return when {
            this < 60 -> "${toInt()} sec"
            minutes < 60 -> "$minutes min"
            else -> "${minutes / 60} h ${minutes % 60} min"
        }
    }

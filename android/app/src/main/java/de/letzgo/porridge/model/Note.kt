package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.store.AudioStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.net.URI
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * iOS: `Note` (Models/Note.swift). Notiz, aufgenommenes Meeting und gespeicherter Link in einem.
 * `text` ist Markdown; Tags sind `#wörter` darin. Feldnamen wie iOS; Zeiten in Millisekunden,
 * `speakersData`/`segmentsData` als JSON-Text derselben Form wie das iOS-JSON.
 */
@Serializable
@Entity(tableName = "notes", indices = [Index("folderID"), Index("deletedAt"), Index("updatedAt")])
data class Note(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    val title: String = "",
    val text: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val statusRaw: String = ProcessingStatus.READY.raw,
    val errorMessage: String? = null,
    /** Aufnahme, die noch transkribiert und an `text` angehängt werden muss. */
    val pendingAudioFileName: String? = null,
    val audioFileNames: List<String> = emptyList(),
    /** Alter Ordner (`NoteFolder.id`); beim Start in [projectIDs] übernommen und geleert. */
    val folderID: String? = null,
    /** Projekte (`NoteFolder.id`), zu denen die Notiz gehört. */
    val projectIDs: List<String> = emptyList(),
    val isPinned: Boolean = false,
    /** Gesetzt, solange die Notiz in „Recently Deleted“ liegt. */
    val deletedAt: Long? = null,
    /** Gespeicherter Link: Adresse und, sobald geladen, der Text der Seite ("" = nichts zu lesen). */
    val url: String? = null,
    val pageText: String? = null,
    /** Tags von Hand oder aus der Zusammenfassung; `#wörter` im Text zählen auch (siehe [tags]). */
    val labels: List<String> = emptyList(),
    val summary: String? = null,
    val summaryModel: String? = null,
    val summarizedAt: Long? = null,
    // Aufgenommene Meetings sind auch Notizen: Aufnahme, Transkript und Sprecher liegen hier.
    val titleIsCustom: Boolean = false,
    val duration: Double = 0.0,
    val inputName: String? = null,
    val channelCount: Int = 1,
    val speakerModeRaw: String = SpeakerMode.NONE.raw,
    /** Die Aufnahme, aus der das Transkript stammt (Meeting). Diktat-Audio steht in `audioFileNames`. */
    val audioFileName: String? = null,
    val speakersData: String? = null,
    val segmentsData: String? = null,
) {
    val status: ProcessingStatus get() = ProcessingStatus.of(statusRaw)
    val isDeleted: Boolean get() = deletedAt != null
    val speakerMode: SpeakerMode get() = SpeakerMode.of(speakerModeRaw)

    val speakers: List<Speaker>
        get() = speakersData?.let { runCatching { PorridgeJson.decodeFromString(TranscriptJson.speakers, it) }.getOrNull() } ?: emptyList()

    val segments: List<TranscriptSegment>
        get() = segmentsData?.let { runCatching { PorridgeJson.decodeFromString(TranscriptJson.segments, it) }.getOrNull() } ?: emptyList()

    fun withSpeakers(value: List<Speaker>) = copy(speakersData = PorridgeJson.encodeToString(TranscriptJson.speakers, value))
    fun withSegments(value: List<TranscriptSegment>) = copy(segmentsData = PorridgeJson.encodeToString(TranscriptJson.segments, value))

    val isLink: Boolean get() = url != null

    /** Die Seite eines Links ohne „www.“, z. B. „github.com“. */
    val domain: String?
        get() {
            val host = url?.let { runCatching { URI(it).host }.getOrNull() } ?: return null
            return host.removePrefix("www.")
        }

    /** Die Notiz stammt aus einer Aufnahme, die (noch) mit Sprechern transkribiert wird. */
    val isRecording: Boolean get() = audioFileName != null || segmentsData != null

    val hasLocalAudio: Boolean get() = AudioStore.exists(audioFileName)

    fun transcriptText(speakers: List<Speaker> = this.speakers, timestamps: Boolean = true): String =
        segments.joinToString("\n") { segment ->
            var prefix = if (timestamps) "[${segment.start.clockString}] " else ""
            segment.speakerId?.let { id -> speakers.firstOrNull { it.id == id }?.let { prefix += "${it.name}: " } }
            prefix + segment.text
        }

    /** Alles der Notiz als Text, zum Teilen. */
    val exportText: String
        get() {
            val parts = mutableListOf<String>()
            if (title.isNotEmpty()) parts += "# $title"
            parts += DateFormat.getDateTimeInstance(DateFormat.LONG, DateFormat.SHORT).format(Date(createdAt))
            url?.let { parts += it }
            if (text.isNotEmpty()) parts += text
            if (!summary.isNullOrEmpty()) parts += "## Summary\n\n$summary"
            if (segmentsData != null && segments.isNotEmpty()) parts += "## Transcript\n\n${transcriptText()}"
            return parts.joinToString("\n\n")
        }

    val displayTitle: String
        get() {
            if (title.isNotBlank()) return title
            val firstLine = NoteText.plainLines(text).firstOrNull().orEmpty()
            if (firstLine.isEmpty() && isRecording) return defaultMeetingTitle(createdAt)
            if (firstLine.isEmpty()) domain?.let { return it }
            if (firstLine.isEmpty()) return if (status == ProcessingStatus.TRANSCRIBING) "New Note" else "Empty Note"
            return firstLine.take(60)
        }

    /** Text für die Listenzeile: der Text ohne Markdown (ohne erste Zeile, wenn sie als Titel dient). */
    val preview: String
        get() {
            val lines = NoteText.plainLines(text)
            val own = (if (title.isBlank()) lines.drop(1) else lines).joinToString(" ")
            if (own.isNotEmpty()) return own
            summary?.let { s -> NoteText.plainLines(s).firstOrNull { !it.startsWith("#") }?.let { return it } }
            segments.firstOrNull()?.let { return it.text }
            return pageText?.take(160)?.replace("\n", " ") ?: (domain ?: "")
        }

    /** Alle Tags: eigenes Tag-Feld und `#wörter` im Text, ohne Doppelte. */
    val tags: List<String>
        get() {
            val seen = HashSet<String>()
            return (labels + NoteText.tags(text)).filter { seen.add(it.lowercase()) }
        }

    /** iOS: `Note.matches` — jedes Wort der Anfrage kommt irgendwo vor (Groß/klein egal). */
    fun matches(query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return true
        val transcript by lazy { if (segmentsData != null) transcriptText(timestamps = false) else "" }
        return q.split(" ").filter { it.isNotEmpty() }.all { word ->
            title.contains(word, true) || text.contains(word, true) ||
                summary?.contains(word, true) == true || url?.contains(word, true) == true ||
                pageText?.contains(word, true) == true || transcript.contains(word, true)
        }
    }

    companion object {
        fun defaultMeetingTitle(millis: Long): String =
            "Meeting · " + SimpleDateFormat("d MMM, HH:mm", Locale.getDefault()).format(Date(millis))

        /** Ein Tag, wie er gespeichert wird: ohne `#`, ohne Leerzeichen. */
        fun cleanTag(raw: String): String =
            raw.trim { it.isWhitespace() || it in "#,.;" }.replace(" ", "-")
    }
}

/**
 * Serializer der JSON-Spalten. Außerhalb von [Note], weil Room (KSP) die vom Serialisierungs-Plugin erst später
 * erzeugten Typen sonst im Entity sieht und abbricht.
 */
internal object TranscriptJson {
    val speakers = ListSerializer(Speaker.serializer())
    val segments = ListSerializer(TranscriptSegment.serializer())
}

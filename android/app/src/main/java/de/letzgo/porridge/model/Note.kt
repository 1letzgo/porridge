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
    /** Gesetzt, solange die Notiz im Archiv liegt; übersteht den Papierkorb. */
    val archivedAt: Long? = null,
    // Alles, was in die App kommt, ist ein Eingang: Er hat einen Kanal, wartet im Eingang und wird in Buckets abgelegt.
    /** Der Kanal, über den die Notiz kam ([NoteSource]); "" bei Notizen aus der Zeit davor. */
    val sourceRaw: String = "",
    /** Dateien der Notiz (geteilte Bilder, PDFs, Dokumente) als JSON von `[Attachment]`; der Text bleibt, wie iOS ihn schrieb. */
    val attachmentsData: String? = null,
    /** Wann die Notiz zum ersten Mal in einen Bucket kam. Ob sie im Eingang liegt, hängt nicht daran ([isInInbox]). */
    val filedAt: Long? = null,
    /** Die für die Notiz vorgeschlagenen Buckets (`NoteFolder.id`); der Nutzer nimmt sie an oder verwirft sie. */
    val suggestedProjectIDs: List<String> = emptyList(),
    // Ein To-do ist eine Notiz wie jede andere mit einem Erledigt-Stand (`logic/Todos.kt`); seine Unteraufgaben sind die
    // Checklisten-Zeilen von `text`. Alle drei fehlen im Sync-Eintrag, solange sie null sind (iOS: `Note.todoStateRaw` …).
    /** [TodoState]: "open", "done" oder "none" für ein To-do, das wieder eine Notiz ist; null = nie ein To-do. */
    val todoStateRaw: String? = null,
    /** Wann das To-do abgehakt wurde (ms); null, solange es offen ist. */
    val todoDoneAt: Long? = null,
    /** Die Notiz (`id`), aus deren Zusammenfassung das To-do stammt. */
    val todoSourceID: String? = null,
) {
    val source: NoteSource get() = NoteSource.of(sourceRaw)

    val attachments: List<Attachment>
        get() = attachmentsData?.let { runCatching { PorridgeJson.decodeFromString(AttachmentJson.list, it) }.getOrNull() } ?: emptyList()

    fun withAttachments(value: List<Attachment>) =
        copy(attachmentsData = if (value.isEmpty()) null else PorridgeJson.encodeToString(AttachmentJson.list, value))

    /** Im Eingang: in keinem Bucket. Alles bleibt dort, bis es in einen kommt, und ist zurück, wenn es seinen letzten verlässt. */
    val isInInbox: Boolean get() = projectIDs.isEmpty() && deletedAt == null && !isArchived

    /** iOS: `Note.isArchived` — von Hand archiviert, oder ein To-do, das vor heute erledigt wurde ([isPutAway]). */
    val isArchived: Boolean get() = archivedAt != null || isPutAway

    // Die Notiz als To-do (iOS: `extension Note` in Services/Todos.swift)

    /** null: eine Notiz, die nie ein To-do war. */
    val todoState: TodoState? get() = TodoState.of(todoStateRaw)

    val isTodo: Boolean get() = todoState == TodoState.OPEN || todoState == TodoState.DONE

    val isDone: Boolean get() = todoState == TodoState.DONE

    val todoProgress: de.letzgo.porridge.logic.Todos.Progress
        get() = if (isTodo) de.letzgo.porridge.logic.Todos.progress(text) else de.letzgo.porridge.logic.Todos.Progress(0, 0)

    /** Ein To-do, das vor heute erledigt wurde: aus den Listen wie eine archivierte Notiz. */
    val isPutAway: Boolean get() = isDone && de.letzgo.porridge.logic.Todos.isPutAway(todoDoneAt)

    /** Jede Notiz außer einer gespeicherten (Link, geteilte Datei) und einem Meeting kann ein To-do sein. */
    val canBeTodo: Boolean get() = !isSaved && !isRecording

    /** iOS: `SyncRecords.apply` — die To-do-Felder einer anderen Notiz (für Einträge, die keine kennen). */
    fun withTodoOf(other: Note) = copy(todoStateRaw = other.todoStateRaw, todoDoneAt = other.todoDoneAt, todoSourceID = other.todoSourceID)

    /** Jede Datei der Notiz im Speicher: ihre Aufnahmen und ihre Anhänge. */
    val storedFileNames: List<String>
        get() = listOfNotNull(audioFileName, pendingAudioFileName) + audioFileNames + attachments.map { it.fileName }

    /** Kam von außen (ein Link, eine geteilte Datei oder Text): etwas zum Aufheben. Daraus entstehen nie Aufgaben. */
    val isSaved: Boolean get() = url != null || source == NoteSource.SHARE

    /** iOS: `SyncRecords.apply` — die Eingangsfelder einer anderen Notiz (für Einträge älterer Versionen, die sie nicht kennen). */
    fun withIntakeOf(other: Note) = copy(
        sourceRaw = other.sourceRaw, attachmentsData = other.attachmentsData, filedAt = other.filedAt,
        suggestedProjectIDs = other.suggestedProjectIDs,
    )

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

    /**
     * iOS: `Note.isStored` — ein Bild oder eine Datei, geteilt oder gewählt: so geführt, nicht als Notiz. Bilder und
     * Dateien sind zwei Arten, die gleich behandelt werden.
     */
    val isStored: Boolean get() = attachmentsData != null && source == NoteSource.SHARE && url == null && !isRecording

    /** iOS: `Note.isImage` — ein Foto oder ein Bildschirmfoto. */
    val isImage: Boolean get() = isStored && attachments.firstOrNull()?.kind == Attachment.Kind.IMAGE

    /** iOS: `Note.isFile` — ein PDF oder ein Dokument. */
    val isFile: Boolean get() = isStored && !isImage

    /** Die Seite eines Links ohne „www.“, z. B. „github.com“. */
    val domain: String?
        get() {
            val host = url?.let { runCatching { URI(it).host }.getOrNull() } ?: return null
            return host.removePrefix("www.")
        }

    /** Die Notiz stammt aus einer Aufnahme, die (noch) mit Sprechern transkribiert wird. */
    val isRecording: Boolean get() = audioFileName != null || segmentsData != null

    val hasLocalAudio: Boolean get() = AudioStore.exists(audioFileName)

    /**
     * Ein später aufgenommener Teil wartet hier, bis er transkribiert ist (`ProcessingService.processContinuation`).
     * Dabei getippte Notizen zählen ab dem Ende dessen, was schon da ist.
     */
    fun withRecordedPart(fileName: String, written: List<RecordingNote>): Note {
        val start = maxOf(duration, segments.lastOrNull()?.end ?: 0.0)
        val typed = RecordingNote.markdown(written.map { it.copy(at = it.at + start) })
        return copy(
            pendingAudioFileName = fileName, statusRaw = ProcessingStatus.RECORDED.raw, updatedAt = System.currentTimeMillis(),
            text = if (typed.isEmpty()) text else if (text.isEmpty()) typed else text + "\n\n" + typed,
        )
    }

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
            if (isTodo) parts += if (isDone) "[x] To-do, done" else "[ ] To-do"
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
            // Ein offenes To-do zeigt, was noch zu tun ist.
            if (isTodo && !isDone) {
                val open = de.letzgo.porridge.logic.Todos.subtasks(text).filter { !it.done }.map { it.text }
                if (open.isNotEmpty()) return NoteText.plainLines(open.joinToString(" · ")).joinToString(" ")
            }
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
internal object AttachmentJson {
    val list = ListSerializer(Attachment.serializer())
}

internal object TranscriptJson {
    val speakers = ListSerializer(Speaker.serializer())
    val segments = ListSerializer(TranscriptSegment.serializer())
}

/**
 * iOS: `TodoState` (Services/Todos.swift) — ob eine Notiz ein To-do ist. Gespeichert als `Note.todoStateRaw`; null = nie
 * ein To-do, damit ihr Sync-Eintrag bleibt, wie er war.
 */
enum class TodoState(val raw: String) {
    OPEN("open"),
    DONE("done"),
    /** War ein To-do und ist wieder eine Notiz: geschrieben, damit die anderen Geräte davon erfahren. */
    NONE("none");

    companion object {
        fun of(raw: String?): TodoState? = entries.firstOrNull { it.raw == raw }
    }
}

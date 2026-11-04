package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.clockString
import java.text.DateFormat
import java.util.Date

/** iOS: `MeetingExport` — Zusammenfassung und Transkript eines Meetings, je nach Wahl. Das PDF macht `data/MeetingPdf.kt`. */
data class MeetingExport(val title: String, val date: String, val summary: String?, val transcript: List<Line>) {
    enum class Format(val title: String, val extension: String, val mime: String) {
        TEXT("Text", "txt", "text/plain"), PDF("PDF", "pdf", "application/pdf"),
    }

    data class Line(val time: String, val speaker: String?, val text: String)

    val isEmpty get() = summary.isNullOrEmpty() && transcript.isEmpty()

    val plainText: String
        get() {
            val parts = mutableListOf(title, date)
            if (!summary.isNullOrEmpty()) parts += "Summary\n\n" + plain(summary)
            if (transcript.isNotEmpty()) parts += "Transcript\n\n" + transcript.joinToString("\n") { line ->
                "[${line.time}] " + (line.speaker?.let { "$it: " } ?: "") + line.text
            }
            return parts.joinToString("\n\n") + "\n"
        }

    /** Der Dateiname: der Titel ohne Zeichen, die in Dateinamen nicht gehen. */
    val fileName: String
        get() = title.replace(Regex("""[/\\:?%*|"<>\n\r]"""), " ").trim().ifEmpty { "Meeting" }

    companion object {
        fun of(note: Note, includeSummary: Boolean, includeTranscript: Boolean): MeetingExport {
            val speakers = note.speakers
            return MeetingExport(
                note.displayTitle,
                DateFormat.getDateTimeInstance(DateFormat.LONG, DateFormat.SHORT).format(Date(note.createdAt)),
                if (includeSummary) note.summary else null,
                if (includeTranscript) note.segments.map { segment ->
                    Line(segment.start.clockString, segment.speakerId?.let { id -> speakers.firstOrNull { it.id == id }?.name }, segment.text)
                } else emptyList(),
            )
        }

        /** Die Zusammenfassung ohne Markdown-Zeichen; Listen bleiben Listen. */
        private fun plain(markdown: String) = markdown.split("\n").joinToString("\n") { raw ->
            val line = raw.trim()
            (if (line.startsWith("#")) line.trimStart('#').trim() else line).replace("**", "")
        }
    }
}

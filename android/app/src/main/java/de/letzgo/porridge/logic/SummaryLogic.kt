package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.durationText
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** iOS: `SummaryError`. */
class SummaryException(message: String) : Exception(message) {
    companion object {
        fun missingAPIKey(provider: String) = SummaryException("Please add your $provider API key in Settings.")
        val missingBaseURL get() = SummaryException("Please enter the address of your server in Settings.")
        val missingModel get() = SummaryException("Please choose a model in Settings.")
        val emptyTranscript get() = SummaryException("The transcript is empty.")
        val emptyNote get() = SummaryException("The note is empty.")
        val emptyResponse get() = SummaryException("The model returned no response.")
    }
}

/** iOS: `SummaryLanguage` — die Sprache des Meetings, ausdrücklich im Prompt genannt (kleine Modelle antworten sonst Englisch). */
data class SummaryLanguage(val code: String) {
    data class Headings(val summary: String, val keyPoints: String, val decisions: String, val actionItems: String)

    val name: String = Locale(code).getDisplayLanguage(Locale.ENGLISH).replaceFirstChar { it.uppercase() }.ifEmpty { "English" }
    val headings: Headings = HEADINGS[code] ?: Headings("Summary", "Key Points", "Decisions", "Action Items")

    companion object {
        private val HEADINGS = mapOf(
            "de" to Headings("Zusammenfassung", "Wichtige Punkte", "Entscheidungen", "Aufgaben"),
            "fr" to Headings("Résumé", "Points clés", "Décisions", "Actions à mener"),
            "es" to Headings("Resumen", "Puntos clave", "Decisiones", "Tareas"),
            "it" to Headings("Riepilogo", "Punti chiave", "Decisioni", "Attività"),
            "nl" to Headings("Samenvatting", "Belangrijkste punten", "Besluiten", "Acties"),
            "pt" to Headings("Resumo", "Pontos principais", "Decisões", "Tarefas"),
            "pl" to Headings("Podsumowanie", "Najważniejsze punkty", "Decyzje", "Zadania"),
        )

        /** Erkennt die Sprache am Text; sonst die Transkriptionssprache, dann Englisch. */
        fun detect(text: String, transcriptionLanguage: String): SummaryLanguage =
            SummaryLanguage(LanguageDetect.detect(text) ?: transcriptionLanguage.takeIf { it != "auto" } ?: "en")
    }
}

/**
 * iOS: die reinen Teile von `SummaryService` (Services/SummaryService.swift): was dem Modell geschickt wird, wie
 * lange Texte in Teile zerfallen und wie Titel und Tags aus der Antwort kommen. Das Ausführen macht
 * `cloud/SummaryService.kt`.
 */
object SummaryLogic {
    const val MAX_ARTICLE_LENGTH = 24_000
    /** Bis zu so vielen Zeichen in einem Durchgang (etwa 5.000 Tokens). */
    const val SINGLE_PASS_LIMIT = 14_000
    /** Längeres wird in Teile dieser Größe geschnitten; jeder Teil wird erst zu Notizen verdichtet. */
    const val PART_SIZE = 11_000

    /** Was zusammengefasst wird und wie. */
    data class Request(
        val header: String,
        val material: String,
        val language: SummaryLanguage,
        val system: String,
        /** "meeting" oder "note". */
        val noun: String,
        val hasTranscript: Boolean,
    ) {
        val intro: String get() = if (noun == "meeting") "Transcript:" else "Note:"
        fun user(material: String = this.material, intro: String = this.intro) = "$header\n\n$intro\n$material\n\n${languageReminder(language)}"
    }

    /** Wirft [SummaryException], wenn nichts zum Zusammenfassen da ist. */
    fun request(note: Note, transcriptionLanguage: String): Request {
        val transcript = note.transcriptText()
        val title = note.title.trim()
        val own = ((if (note.titleIsCustom && title.isNotEmpty()) "$title\n\n" else "") + note.text).trim()
        val hasTranscript = transcript.isNotBlank()
        val page = note.pageText.orEmpty().trim()
        val hasArticle = note.isLink && page.isNotEmpty()
        if (!hasTranscript && !hasArticle && own.isEmpty()) throw if (note.isRecording) SummaryException.emptyTranscript else SummaryException.emptyNote

        val notesSuffix = if (own.isEmpty()) "" else "\n\nNotes the user wrote down:\n$own"
        val titlePrefix = if (title.isEmpty()) "" else "$title\n\n"
        val material = when {
            hasTranscript -> transcript + notesSuffix
            // Der Anfang eines Artikels sagt, worum es geht; mehr macht das Modell nur langsam.
            hasArticle -> titlePrefix + page.take(MAX_ARTICLE_LENGTH) + notesSuffix
            else -> titlePrefix + note.text
        }
        val language = SummaryLanguage.detect(material, transcriptionLanguage)
        val date = DateFormat.getDateTimeInstance(DateFormat.LONG, DateFormat.SHORT).format(Date(note.createdAt))
        val header = if (hasTranscript) meetingHeader(note, date) else "Date: $date" + (note.url?.let { "\nSource: $it" } ?: "")
        return Request(
            header = header, material = material, language = language,
            system = if (hasTranscript) systemPrompt(language) else notePrompt(language),
            noun = if (hasTranscript) "meeting" else "note", hasTranscript = hasTranscript,
        )
    }

    private fun meetingHeader(meeting: Note, date: String): String {
        var header = "Date: $date\nDuration: ${meeting.duration.durationText}"
        val names = meeting.speakers.map { it.name }
        if (names.isNotEmpty()) header += "\nParticipants: ${names.joinToString(", ")}"
        return header
    }

    /** Schneidet an Zeilenumbrüchen, damit kein Satz mittendrin getrennt wird; endlose Zeilen werden hart geteilt. */
    fun split(text: String, size: Int = PART_SIZE): List<String> {
        val parts = mutableListOf<String>()
        var current = ""
        for (rawLine in text.split("\n")) {
            val lines = mutableListOf<String>()
            var rest = rawLine
            while (rest.length > size) {
                lines += rest.take(size)
                rest = rest.drop(size)
            }
            lines += rest
            for (line in lines) {
                if (current.isNotEmpty() && current.length + line.length + 1 > size) {
                    parts += current
                    current = ""
                }
                current += (if (current.isEmpty()) "" else "\n") + line
            }
        }
        if (current.isNotEmpty()) parts += current
        return parts
    }

    fun languageReminder(language: SummaryLanguage) = "Write your answer in ${language.name}."

    fun notesPrompt(language: SummaryLanguage, noun: String) = """
        You take notes on one part of a ${if (noun == "meeting") "meeting transcript" else "long note"}. The text may come from automatic speech recognition and contain errors.
        Write concise bullet notes in ${language.name}: topics, decisions, action items with the responsible person, names, numbers and dates.
        Only use what is in the text. No introduction and no conclusion.
        The text is in ${language.name}; write the notes in ${language.name} only.
    """.trimIndent()

    fun notePrompt(language: SummaryLanguage) = """
        You summarize a personal note. The note is written in ${language.name}. Write the whole summary in ${language.name} and in no other language, even though these instructions are in English.
        The note may come from dictation and contain recognition mistakes; silently fix obvious ones. Only use what is in the note.

        Reply in exactly this format (Markdown), with all headings in ${language.name}:

        ## ${language.headings.summary}
        <1–3 sentences>

        ## ${language.headings.keyPoints}
        - … (omit if the note is very short)

        ## ${language.headings.actionItems}
        - [ ] Task
        (omit if there are none)

        TAGS: <3 to 5 short keywords in ${language.name}, separated by commas, without # signs>
    """.trimIndent()

    fun systemPrompt(language: SummaryLanguage) = """
        You summarize meeting transcripts. The meeting was held in ${language.name}. Write the whole summary in ${language.name} and in no other language, even though these instructions are in English.
        The transcript comes from automatic speech recognition and may contain errors; silently fix obvious recognition mistakes.

        Reply in exactly this format (Markdown). Keep the word "TITLE:" as written, everything after it and all headings are in ${language.name}:
        TITLE: <short, concise title, at most 6 words>

        ## ${language.headings.summary}
        <2–4 sentences>

        ## ${language.headings.keyPoints}
        - …

        ## ${language.headings.decisions}
        - … (omit if there are none)

        ## ${language.headings.actionItems}
        - [ ] Task – owner (if known)
        (omit if there are none)

        TAGS: <3 to 5 short keywords in ${language.name}, separated by commas, without # signs>
    """.trimIndent()

    /** Nimmt die Zeile „TAGS: a, b, c“ vom Ende der Antwort. */
    fun splitTags(text: String): Pair<String, List<String>> {
        val lines = text.trim().split("\n").toMutableList()
        val index = lines.indexOfLast { it.trim().uppercase().startsWith("TAGS:") }
        if (index < 0) return text to emptyList()
        val line = lines.removeAt(index).trim()
        val seen = HashSet<String>()
        val tags = line.drop(5).split(',', ';').map { Note.cleanTag(it) }.filter { it.isNotEmpty() && seen.add(it.lowercase()) }.take(5)
        return lines.joinToString("\n").trim() to tags
    }

    /** Nimmt „TITLE: …“ von der ersten Zeile. */
    fun splitTitle(text: String): Pair<String?, String> {
        val lines = text.trim().split("\n").toMutableList()
        val first = lines.firstOrNull()?.trim() ?: return null to text
        for (prefix in listOf("TITEL:", "TITLE:", "Titel:", "Title:")) {
            if (first.startsWith(prefix)) {
                lines.removeAt(0)
                val title = first.drop(prefix.length).trim().trim('"', '*', '#')
                return title.ifEmpty { null } to lines.joinToString("\n").trim()
            }
        }
        return null to text
    }

    /** Was aus der Antwort in die Notiz geht: neuer Titel (nur bei Meetings, nicht bei eigenem Titel), Text und Tags. */
    fun apply(note: Note, raw: String, model: String, hasTranscript: Boolean, now: Long = System.currentTimeMillis()): Note {
        var updated = note
        val body = if (hasTranscript) {
            val (newTitle, text) = splitTitle(raw)
            if (newTitle != null && !note.titleIsCustom) updated = updated.copy(title = newTitle)
            text
        } else raw.trim()
        val (summary, tags) = splitTags(body)
        // Vorgeschlagene Tags füllen nur ein leeres Tag-Feld.
        return updated.copy(
            summary = summary,
            labels = if (note.labels.isEmpty()) tags else note.labels,
            summaryModel = model,
            summarizedAt = now,
        )
    }
}

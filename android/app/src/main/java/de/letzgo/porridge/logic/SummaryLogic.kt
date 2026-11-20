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
        /** Ein Bild oder eine Datei, aus der sich nichts lesen ließ. */
        fun emptyFile(isImage: Boolean) = SummaryException(if (isImage) "No text could be read from this image." else "No text could be read from this file.")
        val tooLongToEnhance get() = SummaryException("The note is too long for this model. Choose a larger model or a cloud model.")
        val noteChanged get() = SummaryException("The note was changed while it was being enhanced, so your text was kept.")
        val emptyResponse get() = SummaryException("The model returned no response.")
        val truncated get() = SummaryException("The model stopped before the note was finished, so your text was kept. Try a model with a longer output.")
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
        /** Worauf auch die Notizen zu den Teilen achten sollen (aus der Vorlage). */
        val focus: String = "",
    ) {
        val intro: String get() = if (noun == "meeting") "Transcript:" else "Note:"
        fun user(material: String = this.material, intro: String = this.intro) = "$header\n\n$intro\n$material\n\n${languageReminder(language)}"
    }

    /** Wirft [SummaryException], wenn nichts zum Zusammenfassen da ist. */
    fun request(
        note: Note, transcriptionLanguage: String, myName: String? = null, template: SummaryTemplate = SummaryTemplate.GENERAL,
        /** Die Buckets, aus denen das Modell einen vorschlagen darf (`InboxLogic.candidates`). */
        buckets: List<de.letzgo.porridge.model.NoteFolder> = emptyList(),
    ): Request {
        // Ohne Zeitstempel: Das Modell braucht sie nicht, und sie nähmen ihm einen guten Teil seines Platzes.
        val transcript = note.transcriptText(timestamps = false)
        val title = note.title.trim()
        val own = ((if (note.titleIsCustom && title.isNotEmpty()) "$title\n\n" else "") + note.text).trim()
        val hasTranscript = transcript.isNotBlank()
        val page = note.pageText.orEmpty().trim()
        // Eine Seite, oder der aus geteilten Dateien gelesene Text.
        val hasArticle = (note.isLink || note.attachmentsData != null) && page.isNotEmpty()
        if (!hasTranscript && !hasArticle && own.isEmpty()) throw when {
            // Ein Bild oder eine Datei hat keinen Notiztext: Es zählt, was daraus gelesen wurde.
            note.isStored -> SummaryException.emptyFile(note.isImage)
            note.isRecording -> SummaryException.emptyTranscript
            else -> SummaryException.emptyNote
        }

        val notesSuffix = if (own.isEmpty()) "" else "\n\nNotes the user wrote down:\n$own"
        val titlePrefix = if (title.isEmpty()) "" else "$title\n\n"
        val material = when {
            hasTranscript -> transcript + notesSuffix
            // Der Anfang eines Artikels sagt, worum es geht; mehr macht das Modell nur langsam.
            hasArticle -> titlePrefix + page.take(MAX_ARTICLE_LENGTH) + (note.text.trim().takeIf { it.isNotEmpty() }?.let { "\n\nNotes the user wrote down:\n$it" } ?: "")
            else -> titlePrefix + note.text
        }
        val language = SummaryLanguage.detect(material, transcriptionLanguage)
        val date = DateFormat.getDateTimeInstance(DateFormat.LONG, DateFormat.SHORT).format(Date(note.createdAt))
        val header = if (hasTranscript) meetingHeader(note, date, myName) else "Date: $date" + (note.url?.let { "\nSource: $it" } ?: "")
        return Request(
            header = header, material = material, language = language,
            system = (if (hasTranscript) systemPrompt(language, template) else notePrompt(language, note.isSaved, isDocument = !note.isLink)) + InboxLogic.promptLine(buckets),
            noun = if (hasTranscript) "meeting" else "note", hasTranscript = hasTranscript,
            focus = if (hasTranscript) template.focus else "",
        )
    }

    /** [myName]: wer aufnimmt (der Nutzer), damit seine Aufgaben seinen Namen tragen. */
    private fun meetingHeader(meeting: Note, date: String, myName: String?): String {
        var header = "Date: $date\nDuration: ${meeting.duration.durationText}"
        val names = meeting.speakers.map { it.name }
        if (names.isNotEmpty()) header += "\nParticipants: ${names.joinToString(", ")}"
        myName?.split(",")?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let { header += "\nRecorded by: $it" }
        return header
    }

    /**
     * Was das Modell von jedem Teil liest: wer und wann, damit ein Teil für sich verständlich ist, und das Ende des
     * Teils davor, damit ein Thema über den Schnitt hinweg ganz bleibt.
     */
    fun partPrompts(material: String, header: String, size: Int = PART_SIZE): List<String> {
        val parts = split(material, size)
        return parts.mapIndexed { index, part ->
            var prompt = "$header\n\nPart ${index + 1} of ${parts.size}:\n\n"
            if (index > 0) {
                val tail = parts[index - 1].takeLast(size / 10)
                // Ab einem Zeilenanfang, wo es einen gibt, damit das Wiederholte nicht mitten im Satz beginnt.
                prompt += "End of the previous part, only for context:\n${tail.substringAfter("\n", tail)}\n\nThis part:\n"
            }
            prompt + part
        }
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

    fun notesPrompt(language: SummaryLanguage, noun: String, focus: String = "") = """
        You take notes on one part of a ${if (noun == "meeting") "meeting transcript" else "long note"}. The text may come from automatic speech recognition and contain errors.
        Write concise bullet notes in ${language.name}: topics, decisions, action items with the responsible person, names, numbers and dates.${if (noun == "meeting") " Start every decision with \"DECISION:\" and every task with \"TASK:\", then the responsible person and the due date if they are named." else ""}
        Only use what is in the text. No introduction and no conclusion.
        The text is in ${language.name}; write the notes in ${language.name} only.
    """.trimIndent() + if (focus.isEmpty()) "" else "\n$focus"

    /** Eine gespeicherte Seite wird nur zusammengefasst: eine Seite gibt nie Aufgaben (`isLink`). */
    fun notePrompt(language: SummaryLanguage, isLink: Boolean = false, isDocument: Boolean = false): String {
        val what = if (isDocument) "something the user saved: a document, a screenshot or a text shared from another app. Text read from images may contain recognition mistakes" else "a web page the user saved"
        val intro = if (isLink) {
            "You summarize $what. Write the whole summary in ${language.name} and in no other language, even though these instructions are in English.\nOnly use what is on the page. Do not write tasks or to-dos: a page is read, not worked on."
        } else {
            "You summarize a personal note. The note is written in ${language.name}. Write the whole summary in ${language.name} and in no other language, even though these instructions are in English.\nThe note may come from dictation and contain recognition mistakes; silently fix obvious ones. Only use what is in the note."
        }
        val tasks = if (isLink) "" else "\n## ${language.headings.actionItems}\n- [ ] <a concrete task from the note> – <due date as YYYY-MM-DD, only if a date or deadline is named>\n(omit this heading if there are none; leave out the date when none is named)\n"
        return intro + "\n\nReply in exactly this format (Markdown), with all headings in ${language.name}:\n\n" +
            "## ${language.headings.summary}\n<1–3 sentences>\n\n" +
            "## ${language.headings.keyPoints}\n- … (omit if the ${if (isLink) "page" else "note"} is very short)\n" +
            tasks + "\nTAGS: <3 to 5 short keywords in ${language.name}, separated by commas, without # signs>"
    }

    fun systemPrompt(language: SummaryLanguage, template: SummaryTemplate = SummaryTemplate.GENERAL): String {
        val sections = template.sections?.joinToString("\n\n") { "## <\"$it\" in ${language.name}>\n- … (omit if nothing fits)" }
            ?: "## ${language.headings.keyPoints}\n- …\n\n## ${language.headings.decisions}\n- … (omit if there are none)"
        val focus = if (template.focus.isEmpty()) "" else "\n${template.focus}"
        return "You summarize meeting transcripts. The meeting was held in ${language.name}. Write the whole summary in ${language.name} and in no other language, even though these instructions are in English.\n" +
            "The transcript comes from automatic speech recognition and may contain errors; silently fix obvious recognition mistakes.\n" +
            "Only use what is in the transcript; never invent tasks, owners, dates or decisions. A task is something a person committed to or was asked to do, not an idea or a topic. Resolve relative dates like \"next Friday\" from the meeting's \"Date\".\n" +
            "If you are given notes, every line marked TASK: or DECISION: belongs in the matching section, without that mark.$focus\n\n" +
            "Reply in exactly this format (Markdown). Keep the word \"TITLE:\" as written, everything after it and all headings are in ${language.name}:\n" +
            "TITLE: <short, concise title, at most 6 words>\n\n" +
            "## ${language.headings.summary}\n<2–4 sentences>\n\n" +
            "$sections\n\n" +
            "## ${language.headings.actionItems}\n- [ ] <a concrete task from the transcript, as a short instruction that is clear on its own> – <owner, if known> – <deadline as YYYY-MM-DD, if one was named>\n" +
            "(one line for every task a person took on (\"I'll do …\", \"can you …\" – \"yes\"), also small ones; omit this heading if there are none. The deadline is the day the task is due, worked out from the meeting's \"Date\" (\"next Friday\", \"end of the month\", \"by 3 December\"), not the day of the meeting unless it is due that day; leave out the owner or the deadline when they are not named, never write a placeholder. A task for the person who recorded, see \"Recorded by\", gets that name as owner)\n\n" +
            "TAGS: <3 to 5 short keywords in ${language.name}, separated by commas, without # signs>"
    }

    /** Nimmt die Zeile „TAGS: a, b, c“ vom Ende der Antwort. */
    /** Kleine Modelle lassen bei einer Aufgabe manchmal das "- " weg; ohne das fehlte sie in der Aufgabenliste. */
    fun withListMarks(summary: String): String =
        summary.split("\n").joinToString("\n") { if (it.startsWith("[ ]") || it.startsWith("[x]")) "- $it" else it }

    fun splitTags(text: String): Pair<String, List<String>> {
        val lines = text.trim().split("\n").toMutableList()
        val index = lines.indexOfLast { it.trim().uppercase().startsWith("TAGS:") }
        if (index < 0) return text to emptyList()
        val line = lines.removeAt(index).trim()
        val seen = HashSet<String>()
        val tags = line.drop(5).split(',', ';').map { Note.cleanTag(it) }.filter { it.isNotEmpty() && seen.add(it.lowercase()) }.take(5)
        return lines.joinToString("\n").trim() to tags
    }

    /** iOS: `SummaryService.enhancePrompt` — schreibt eine einfache Notiz um, statt sie zusammenzufassen. */
    fun enhancePrompt(language: SummaryLanguage) = """
        You improve a personal note. The note is written in ${language.name}. Write the improved note in ${language.name} only, even though these instructions are in English.
        - Fix spelling, grammar and punctuation, and silently fix obvious dictation mistakes.
        - Keep the meaning, every fact, name, number and date, and the author's voice. Do not summarize, leave nothing out and add nothing new.
        - Give it structure: short paragraphs, "- " lists for enumerations, and "## " headings only when the note covers several topics.
        - Write every concrete task (something the author has to do) as its own line "- [ ] <task>". Keep existing "- [ ]" and "- [x]" lines.
        - Use only these marks: "## ", "- ", "1. ", "- [ ] ", "- [x] ", "**bold**". No introduction, no comment, no code block.

        After the note, as the very last line:
        TAGS: <3 to 5 short keywords in ${language.name}, separated by commas, without # signs>
    """.trimIndent()

    /** Manche Modelle packen die Antwort trotz Bitte in ```. */
    fun withoutCodeFence(text: String): String {
        val lines = text.trim().split("\n").toMutableList()
        if (lines.firstOrNull()?.startsWith("```") == true) lines.removeAt(0)
        if (lines.lastOrNull()?.trim() == "```") lines.removeAt(lines.size - 1)
        return lines.joinToString("\n")
    }

    /**
     * iOS: `SummaryService.enhance` — legt den verbesserten Text auf den aktuellen Stand der Notiz. Wurde inzwischen
     * getippt ([original] passt nicht mehr), gewinnt der eigene Text: `noteChanged`.
     */
    fun applyEnhance(current: Note, original: String, raw: String, now: Long = System.currentTimeMillis()): Note {
        val (body, tags) = splitTags(withoutCodeFence(raw))
        val enhanced = withListMarks(body).trim()
        if (enhanced.isEmpty()) throw SummaryException.emptyResponse
        // Das Ergebnis ersetzt die Notiz: Eines, das mittendrin endet, kostete den Rest.
        if (isCutShort(enhanced, original.trim())) throw SummaryException.truncated
        if (current.text != original) throw SummaryException.noteChanged
        return current.copy(text = enhanced, labels = if (current.labels.isEmpty()) tags else current.labels, updatedAt = now)
    }

    /** iOS: `SummaryService.enhanceTokenLimit` — Platz für die ganze Notiz samt Zeichen; ein Token sind etwa drei Zeichen. */
    fun enhanceTokenLimit(text: String): Int = minOf(8_000, text.length / 2 + 600)

    /**
     * iOS: `SummaryService.isCutShort` — eine verbesserte Notiz behält jede Angabe und ist etwa so lang wie die Notiz.
     * Viel kürzer: Dem Modell ging der Platz aus, oder es hat zusammengefasst. Kurze Notizen bleiben außen vor.
     */
    fun isCutShort(enhanced: String, original: String): Boolean = original.length >= 400 && enhanced.length * 2 < original.length

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
    /**
     * Das Ergebnis einer Zusammenfassung auf dem frischen Stand [current] der Notiz: Sie läuft lange, und was in der
     * Zeit an der Notiz geschah, bleibt. [before] ist der Stand, aus dem [summarized] entstand.
     */
    /**
     * iOS: `SummaryService.removeSummary` — nimmt die Zusammenfassung weg. `summarizedAt` bleibt: Ein Eintrag, dessen
     * geschriebene Zusammenfassung gelöscht wurde, wird nicht von selbst wieder zusammengefasst (`AutoSummary`), hier und auf
     * anderen Geräten. Ein Editor, der auf keiner Zusammenfassung geöffnet und geschlossen wurde, lässt es null.
     */
    fun removeSummary(note: Note, now: Long = System.currentTimeMillis()): Note = note.copy(summary = null, summaryModel = null, updatedAt = now)

    fun carryOver(summarized: Note, before: Note, current: Note, now: Long = System.currentTimeMillis()): Note = current.copy(
        title = if (summarized.title != before.title && !current.titleIsCustom) summarized.title else current.title,
        summary = summarized.summary,
        labels = if (current.labels.isEmpty()) summarized.labels else current.labels,
        summaryModel = summarized.summaryModel,
        summarizedAt = summarized.summarizedAt,
        // Nur ein Vorschlag, und nur solange die Notiz noch im Eingang liegt.
        suggestedProjectIDs = if (current.isInInbox && summarized.suggestedProjectIDs.isNotEmpty()) summarized.suggestedProjectIDs else current.suggestedProjectIDs,
        // Ihre Aufgaben werden auf der Seite als To-dos angeboten; nichts entsteht ohne Tipp (iOS: `TodoSuggestions.offer`).
        todoSuggestionsRaw = if (current.isSaved || current.todoSuggestionsRaw != null) current.todoSuggestionsRaw else TodoSuggestions.encode(emptyMap()),
        updatedAt = now,
    )

    fun apply(
        note: Note, answer: String, model: String, hasTranscript: Boolean, now: Long = System.currentTimeMillis(),
        buckets: List<de.letzgo.porridge.model.NoteFolder> = emptyList(),
    ): Note {
        val (raw, bucket) = InboxLogic.splitProject(answer, buckets)
        var updated = if (bucket != null && note.isInInbox) note.copy(suggestedProjectIDs = listOf(bucket.id)) else note
        val body = if (hasTranscript) {
            val (newTitle, text) = splitTitle(raw)
            if (newTitle != null && !note.titleIsCustom) updated = updated.copy(title = newTitle)
            text
        } else raw.trim()
        val (summary, tags) = splitTags(body)
        // Vorgeschlagene Tags füllen nur ein leeres Tag-Feld.
        return updated.copy(
            summary = withListMarks(summary),
            labels = if (note.labels.isEmpty()) tags else note.labels,
            summaryModel = model,
            summarizedAt = now,
        )
    }
}

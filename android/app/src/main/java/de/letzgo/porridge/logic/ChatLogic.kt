package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ChatSource
import de.letzgo.porridge.model.Note
import java.text.DateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Date
import kotlin.math.ln
import kotlin.math.max

/**
 * iOS: `ChatRetrieval` (Services/ChunkRanking.swift) und `ChatService.prompt` / `sources` (Services/ChatService.swift) —
 * findet die Passagen, die zu einer Frage passen (nach Wörtern, BM25), und baut daraus, was das Modell gefragt wird. Den
 * Zusammenhang einer Frage mit ihren Filtern baut `ChatLogic.context` (`ChatDocument.kt`, iOS: Services/ChatDocument.swift).
 * Auf Android zählen nur die Wörter; die Satzvektoren von iOS gibt es hier nicht.
 */
object ChatLogic {
    private fun length(chunk: NoteChunk) = max(chunk.frequencies.values.sum(), 1)

    /** Die Passagen, die am besten zu [question] passen, innerhalb von [budget] Zeichen. */
    fun search(question: String, chunks: List<NoteChunk>, budget: Int = 6500): List<NoteChunk> =
        search(queryWords(question), chunks, budget)

    /** iOS: `search(words:in:)` — [search] mit den schon aus der Frage gelesenen Wörtern (`ChatQuery.words`). */
    fun search(words: List<String>, chunks: List<NoteChunk>, budget: Int = 6500): List<NoteChunk> {
        val unique = words.toSet()
        if (unique.isEmpty() || chunks.isEmpty()) return emptyList()
        val average = chunks.sumOf { length(it) }.toDouble() / chunks.size
        val scores = DoubleArray(chunks.size)
        for (word in unique) {
            val containing = chunks.count { NoteChunks.frequency(word, it) > 0 }
            if (containing == 0) continue
            val idf = ln(1 + (chunks.size - containing + 0.5) / (containing + 0.5))
            chunks.forEachIndexed { index, chunk ->
                val tf = NoteChunks.frequency(word, chunk)
                if (tf > 0) scores[index] += idf * tf * 2.4 / (tf + 1.4 * (1 - 0.75 + 0.75 * length(chunk) / max(average, 1.0)))
            }
        }
        val picked = mutableListOf<NoteChunk>()
        val perNote = HashMap<String, Int>()
        var used = 0
        for (index in chunks.indices.filter { scores[it] > 0 }.sortedByDescending { scores[it] }) {
            val chunk = chunks[index]
            if ((perNote[chunk.noteID] ?: 0) >= PASSAGES_PER_NOTE) continue
            if (used + chunk.text.length > budget && picked.isNotEmpty()) break
            picked += chunk
            perNote[chunk.noteID] = (perNote[chunk.noteID] ?: 0) + 1
            used += chunk.text.length
            if (picked.size >= 10) break
        }
        return picked
    }

    /** Höchstens so viele Passagen einer Notiz: Eine lange Notiz soll nicht alle Plätze belegen. */
    const val PASSAGES_PER_NOTE = 3

    /**
     * iOS: `ChatRetrieval.select` — die Passagen, aus denen eine Chat-Frage beantwortet wird. Nennt die Frage eine Zeit
     * („der letzten Tage“, „this week“), zählen zuerst die Notizen dieser Zeit; passt dort nichts, alle. Ohne ein Wort zum
     * Suchen („Was war diese Woche?“) sind die neuesten Notizen (dieser Zeit) der Zusammenhang.
     */
    fun select(question: String, chunks: List<NoteChunk>, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): List<NoteChunk> {
        var window: List<NoteChunk> = emptyList()
        val start = since(question, now, zone)
        if (start != null) {
            window = chunks.filter { it.date >= start }
            val found = search(question, window)
            if (found.isNotEmpty()) return found
        }
        val found = search(question, chunks)
        if (found.isNotEmpty()) return found
        return recent(window.ifEmpty { chunks }, now = now)
    }

    /**
     * iOS: `ChatRetrieval.queryWords` — die Wörter einer Frage, nach denen sich zu suchen lohnt: ohne die Wörter, die
     * jeder Text hat, ohne die Form der Bitte („stelle mir … vor“) und ohne die Wörter der Zeit, die [since] liest.
     * Nur Fragen werden so gekürzt; die Passagen behalten alle Wörter.
     */
    fun queryWords(question: String): List<String> = NoteChunks.tokens(question).filter { it !in stopWords }

    /** iOS: `ChatRetrieval.stopWords` — dieselbe Liste. */
    val stopWords: Set<String> = setOf(
        // Deutsch: Artikel, Pronomen, Präpositionen, Bindewörter, Hilfsverben
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mir", "mich", "dir", "dich", "uns", "euch", "ihm", "ihn", "ihnen",
        "mein", "meine", "meinen", "meinem", "meiner", "dein", "deine", "unser", "unsere", "unseren", "unserem", "sein", "seine",
        "und", "oder", "aber", "doch", "denn", "dass", "ob", "wenn", "als", "wie", "so", "auch", "noch", "nur", "schon",
        "nicht", "kein", "keine", "keinen", "sehr", "mal", "bitte", "gerne", "gern", "etwa", "ja", "nein",
        "in", "im", "an", "am", "auf", "aus", "bei", "beim", "mit", "nach", "von", "vom", "vor", "zu", "zum", "zur",
        "für", "über", "unter", "um", "bis", "seit", "durch", "gegen", "ohne", "zwischen", "ab",
        "ist", "sind", "war", "waren", "bin", "bist", "seid", "wird", "werden", "wurde", "wurden", "hat", "habe", "haben",
        "hatte", "hatten", "hast", "kann", "können", "konnte", "soll", "sollen", "muss", "müssen", "will", "wollen", "gibt", "gab",
        "was", "wer", "wen", "wem", "wo", "wann", "warum", "wieso", "weshalb", "welche", "welcher", "welches", "welchen", "woran", "worüber",
        "hier", "da", "dort", "dann", "jetzt", "alle", "alles", "allen", "etwas", "viel", "viele", "mehr", "einige", "paar",
        // Deutsch: die Form einer Bitte
        "stelle", "stell", "stellen", "zeig", "zeige", "zeigen", "nenne", "nenn", "nennen", "gib", "geben", "sag", "sage", "sagen",
        "erzähl", "erzähle", "erzählen", "fasse", "fass", "zusammen", "zusammenfassen", "liste", "auflisten", "finde", "finden",
        "suche", "such", "erkläre", "erklär", "beschreibe", "vorstellen", "möchte", "würde", "wüsste", "weißt", "kannst", "könntest",
        "thema", "themen", "bezug", "gespeichert", "notiert", "gemerkt", "abgelegt", "steht", "stehen", "liegt", "liegen", "drin",
        "beschäftigt",
        "highlights", "überblick", "übersicht", "zusammenfassung", "neuigkeiten", "neues", "infos", "informationen",
        // Deutsch: Zeit (liest `since`)
        "heute", "gestern", "vorgestern", "letzte", "letzten", "letzter", "letztes", "vergangene", "vergangenen", "vergangener",
        "diese", "dieser", "diesen", "diesem", "dieses", "tage", "tagen", "woche", "wochen", "monat", "monate", "monaten",
        "zeit", "kürzlich", "neulich", "zuletzt", "neueste", "neuesten", "aktuell", "aktuelle", "aktuellen",
        // Englisch
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "into", "over",
        "is", "are", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had", "can", "could", "would", "should", "will",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "she", "it", "they", "them", "their", "this", "that", "these", "those",
        "what", "which", "who", "whom", "when", "where", "why", "how", "there", "here", "any", "all", "some", "please", "tell",
        "show", "give", "list", "find", "summarize", "summary", "overview", "explain", "describe", "know",
        "topic", "topics", "saved", "stored", "kept", "noted", "regarding", "related",
        "today", "yesterday", "last", "past", "few", "days", "day", "week", "weeks", "month", "months", "recent", "recently", "lately", "latest", "new",
    )

    private val dayWords = setOf("tag", "tage", "tagen", "day", "days")
    private val weekWords = setOf("woche", "wochen", "week", "weeks")
    private val monthWords = setOf("monat", "monate", "monaten", "month", "months")
    private val numberWords = mapOf(
        "ein" to 1, "einen" to 1, "einem" to 1, "eine" to 1, "zwei" to 2, "drei" to 3, "vier" to 4, "fünf" to 5, "sechs" to 6, "sieben" to 7, "acht" to 8, "neun" to 9, "zehn" to 10,
        "one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5, "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10,
    )

    /**
     * iOS: `ChatRetrieval.since` — seit wann eine Frage fragt („heute“, „der letzten Tage“, „last 3 days“, „this week“),
     * in Millisekunden; null, wenn sie keine Zeit nennt. Wochen beginnen am Montag.
     */
    fun since(question: String, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): Long? {
        val words = question.lowercase().split(Regex("""[^\p{L}\p{N}]+""")).filter { it.isNotEmpty() }
        val text = " " + words.joinToString(" ") + " "
        fun has(vararg phrases: String) = phrases.any { text.contains(" $it ") }
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        fun ms(date: LocalDate) = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val thisWeek = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val thisMonth = today.withDayOfMonth(1)

        // „der letzten 3 Tage“, „last two weeks“
        for (index in 0 until words.size - 1) {
            val count = words[index].toIntOrNull() ?: numberWords[words[index]] ?: continue
            if (count <= 0 || count >= 1000) continue
            val unit = words[index + 1]
            if (unit in dayWords) return ms(today.minusDays(count.toLong()))
            if (unit in weekWords) return ms(today.minusDays(7L * count))
            if (unit in monthWords) return ms(today.minusMonths(count.toLong()))
        }
        if (has("heute", "today")) return ms(today)
        if (has("vorgestern")) return ms(today.minusDays(2))
        if (has("gestern", "yesterday")) return ms(today.minusDays(1))
        if (has("diese woche", "dieser woche", "diesen woche", "this week")) return ms(thisWeek)
        if (has("letzte woche", "letzten woche", "letzter woche", "vergangene woche", "vergangenen woche", "last week", "past week")) return ms(thisWeek.minusDays(7))
        if (has("diesen monat", "diesem monat", "dieser monat", "this month")) return ms(thisMonth)
        if (has("letzten monat", "letzter monat", "letzte monat", "vergangenen monat", "last month", "past month")) return ms(thisMonth.minusMonths(1))
        if (has(
                "letzten tage", "letzte tage", "letzten tagen", "vergangenen tage", "vergangenen tagen", "paar tage", "paar tagen",
                "letzter zeit", "letzten zeit", "kürzlich", "neulich", "zuletzt", "neueste", "neuesten",
                "last days", "last few days", "past days", "past few days", "recent", "recently", "lately", "latest",
            )) return ms(today.minusDays(7))
        return null
    }

    /**
     * Passt nichts („was kam diese Woche?“), sind die neuesten Passagen der Zusammenhang. Die Passage eines To-dos trägt
     * seinen fälligen Tag: Eins, das nächsten Monat fällig ist, ist nicht der neueste Eintrag.
     */
    fun recent(chunks: List<NoteChunk>, budget: Int = 4500, now: Long = System.currentTimeMillis()): List<NoteChunk> {
        val picked = mutableListOf<NoteChunk>()
        var used = 0
        for (chunk in chunks.sortedByDescending { minOf(it.date, now) }) {
            if (used + chunk.text.length > budget && picked.isNotEmpty()) break
            picked += chunk
            used += chunk.text.length
            if (picked.size >= 8) break
        }
        return picked
    }

    /** Die Notizen, über die ein Chat geht: alle lebenden, oder die seines Buckets. */
    fun scope(projectID: String?, notes: List<Note>): List<Note> =
        notes.filter { !it.isDeleted && (projectID == null || projectID in it.projectIDs) }

    /** Ein Titel für einen Chat aus seiner ersten Frage. */
    fun title(question: String): String {
        val line = question.lineSequence().firstOrNull { it.isNotBlank() }?.trim() ?: question.trim()
        return if (line.length > 60) line.take(57).trim() + "…" else line
    }

    fun system(bucket: String?, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String =
        "Today is ${DateFormat.getDateInstance(DateFormat.FULL).format(Date(now))} (${ChatDocument.dayText(now, zone)}).\n" +
            "You are the assistant of a private notes app. Answer the question only from the entries and excerpts below; do not use outside knowledge and do not guess. They are taken from the user's notes, meetings (transcripts and summaries), to-dos, saved web links (with the text of the page), images and files (with the text read out of them)" +
            (bucket?.let { ", all of them filed in the bucket \"$it\"" } ?: "") + ".\n" +
            "Every item starts with a number in brackets and a header: «title» — kind (for a to-do its state, due day and subtasks), the day it was created, its bucket (or Inbox), tags, and for a link its address. Use the header for questions about kind, dates, buckets and to-dos.\n" +
            "When a list of matching entries is given, it holds every entry of the kind, bucket, to-do state or time the question asks for: answer list questions from it in full and add nothing that is not in it. When the question also names a topic, take those entries of the list that are about it (they come first and say what they mention).\n" +
            "Write the answer itself in full words: name every entry you mention by its title and give the facts the question asks for (for a to-do its due day, for a link its address, for a meeting what was said or decided). Put the numbers of the items you used after the facts, like: Hecke schneiden, due 22 November [2]. Never answer with numbers alone.\n" +
            "If the items do not contain the answer, say plainly that you found nothing about it in the notes.\n" +
            "Always answer in the language the question is written in (a German question gets a German answer). Be concise."

    /**
     * iOS: `ChatService.prompt` (user part). [history]: die letzten Nachrichten als (ist vom Nutzer, Text). [limit] kürzt den
     * Zusammenhang für ein Modell mit wenig Platz: zuerst die Liste der Treffer (das Modell erfährt, wie viele fehlen), dann
     * die Passagen, die besten zuerst.
     */
    fun user(question: String, history: List<Pair<Boolean, String>>, context: ChatContext, limit: Int = Int.MAX_VALUE): String {
        val text = StringBuilder()
        if (history.isNotEmpty()) {
            text.append("Conversation so far:\n")
            for ((isUser, message) in history) text.append(if (isUser) "User: " else "Assistant: ").append(message.take(500)).append('\n')
            text.append('\n')
        }
        val items = context.items
        var number = 0
        context.matched?.let { matched ->
            val listing = items.filter { it.isListing }
            val lines = mutableListOf<String>()
            var size = text.length
            for (item in listing) {
                val line = "[${number + 1}] ${item.header}" + (if (item.text.isEmpty()) "" else "\n    " + item.text)
                if (size + line.length > limit / 2 && lines.isNotEmpty()) break
                lines += line
                size += line.length + 1
                number += 1
            }
            if (matched == 0) {
                text.append("No entry matches (${context.filter}).\n\n")
            } else {
                val shown = if (lines.size < matched) "the first ${lines.size} of $matched entries" else "all $matched entr${if (matched == 1) "y" else "ies"}"
                text.append("Matching entries (${context.filter}): $shown.\n").append(lines.joinToString("\n")).append("\n\n")
            }
            // Die nicht gezeigten Einträge behalten ihre Nummern außerhalb des Prompts: Der Rest zählt von hier weiter.
            number = listing.size
        }
        val inside = items.filter { !it.isListing && !it.isOutside }
        val outside = items.filter { it.isOutside }
        fun block(title: String, list: List<ChatContextItem>, start: Int) {
            if (list.isEmpty()) return
            text.append(title).append('\n')
            for ((offset, item) in list.withIndex()) {
                if (text.length + item.text.length > limit && offset > 0) break
                text.append("[${start + offset + 1}] ${item.header}\n${item.text}\n\n")
            }
        }
        block(if (context.matched == null) "Excerpts:" else "Excerpts from the matching entries:", inside, number)
        block(
            if (context.matched == null) "Excerpts:" else "Excerpts from other entries (they do not match ${context.filter}; use them only if they answer the question):",
            outside, number + inside.size,
        )
        return text.append("Question: ").append(question).toString()
    }

    /**
     * Die Notizen hinter den Einträgen, die die Antwort als [n] nennt; ohne Nummer die ersten Passagen (nicht die Liste der
     * Treffer, die lang sein kann).
     */
    fun sources(answer: String, items: List<ChatContextItem>): List<ChatSource> {
        val numbers = Regex("""\[([0-9, ]+)]""").findAll(answer).flatMap { match -> match.groupValues[1].split(',', ' ').mapNotNull { it.trim().toIntOrNull() } }.toList()
        var indices = numbers.filter { it in 1..items.size }.map { it - 1 }
        if (indices.isEmpty()) {
            val passages = items.indices.filter { !items[it].isListing && !items[it].isOutside }
            indices = passages.ifEmpty { items.indices.toList() }.take(3)
        }
        val seen = HashSet<String>()
        return indices.mapNotNull { index -> items[index].takeIf { seen.add(it.noteID) }?.let { ChatSource(it.noteID, it.title, it.date) } }
    }
}

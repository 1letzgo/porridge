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
 * iOS: `ChatRetrieval` (Services/ChunkRanking.swift) und `ChatService.prompt` / `sources` — findet die Passagen, die
 * zu einer Frage passen (nach Wörtern, BM25), und baut daraus, was das Modell gefragt wird. Auf Android zählen nur die
 * Wörter; die Satzvektoren von iOS gibt es hier nicht.
 */
object ChatLogic {
    /** Eine Passage mit dem, was das Modell über ihre Notiz wissen soll. */
    data class Passage(val noteID: String, val title: String, val date: Long, val text: String)

    private fun length(chunk: NoteChunk) = max(chunk.frequencies.values.sum(), 1)

    private fun passage(chunk: NoteChunk, notes: Map<String, Note>): Passage? =
        notes[chunk.noteID]?.let { Passage(chunk.noteID, it.displayTitle, it.createdAt, chunk.text) }

    /** Die Passagen, die am besten zu [question] passen, innerhalb von [budget] Zeichen. [notes] sind die Notizen, über die der Chat geht. */
    fun search(question: String, chunks: List<NoteChunk>, notes: Map<String, Note>, budget: Int = 6500): List<Passage> {
        val pool = chunks.filter { it.noteID in notes }
        val words = queryWords(question).toSet()
        if (words.isEmpty() || pool.isEmpty()) return emptyList()
        val average = pool.sumOf { length(it) }.toDouble() / pool.size
        val scores = DoubleArray(pool.size)
        for (word in words) {
            val containing = pool.count { NoteChunks.frequency(word, it) > 0 }
            if (containing == 0) continue
            val idf = ln(1 + (pool.size - containing + 0.5) / (containing + 0.5))
            pool.forEachIndexed { index, chunk ->
                val tf = NoteChunks.frequency(word, chunk)
                if (tf > 0) scores[index] += idf * tf * 2.4 / (tf + 1.4 * (1 - 0.75 + 0.75 * length(chunk) / max(average, 1.0)))
            }
        }
        val picked = mutableListOf<Passage>()
        val perNote = HashMap<String, Int>()
        var used = 0
        for (index in pool.indices.filter { scores[it] > 0 }.sortedByDescending { scores[it] }) {
            val passage = passage(pool[index], notes) ?: continue
            if ((perNote[passage.noteID] ?: 0) >= PASSAGES_PER_NOTE) continue
            if (used + passage.text.length > budget && picked.isNotEmpty()) break
            picked += passage
            perNote[passage.noteID] = (perNote[passage.noteID] ?: 0) + 1
            used += passage.text.length
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
    fun select(question: String, chunks: List<NoteChunk>, notes: Map<String, Note>, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): List<Passage> {
        var window: Map<String, Note> = emptyMap()
        val start = since(question, now, zone)
        if (start != null) {
            window = notes.filterValues { it.createdAt >= start }
            val found = search(question, chunks, window)
            if (found.isNotEmpty()) return found
        }
        val found = search(question, chunks, notes)
        if (found.isNotEmpty()) return found
        return recent(chunks, window.ifEmpty { notes })
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

    /** Passt nichts („was kam diese Woche?“), sind die neuesten Notizen der Zusammenhang. */
    fun recent(chunks: List<NoteChunk>, notes: Map<String, Note>, budget: Int = 4500): List<Passage> {
        val picked = mutableListOf<Passage>()
        var used = 0
        for (passage in chunks.mapNotNull { passage(it, notes) }.sortedByDescending { it.date }) {
            if (used + passage.text.length > budget && picked.isNotEmpty()) break
            picked += passage
            used += passage.text.length
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

    fun system(bucket: String?, now: Long = System.currentTimeMillis()): String =
        "Today is ${DateFormat.getDateInstance(DateFormat.FULL).format(Date(now))}.\n" +
            "You are the assistant of a private notes app. Answer the question using only the excerpts below. They are taken from the user's notes, meeting transcripts, saved web links (with the text of the page), images and files (with the text read out of them)" +
            (bucket?.let { ", all of them filed in the bucket \"$it\"" } ?: "") + ".\n" +
            "Every excerpt starts with a number in brackets, then the title of its note, its date and the buckets it is filed in. Name the numbers of the excerpts you used, like [2].\n" +
            "If the excerpts do not contain the answer, say so briefly. Answer in the language of the question and be concise."

    /** [history]: die letzten Nachrichten als (ist vom Nutzer, Text). [buckets]: die Namen der Buckets je Notiz. */
    fun user(question: String, history: List<Pair<Boolean, String>>, passages: List<Passage>, buckets: Map<String, List<String>>, limit: Int = Int.MAX_VALUE): String {
        val text = StringBuilder()
        if (history.isNotEmpty()) {
            text.append("Conversation so far:\n")
            for ((isUser, message) in history) text.append(if (isUser) "User: " else "Assistant: ").append(message.take(500)).append('\n')
            text.append('\n')
        }
        text.append("Excerpts:\n")
        passages.forEachIndexed { index, passage ->
            if (text.length + passage.text.length > limit) return@forEachIndexed
            val place = buckets[passage.noteID].orEmpty().ifEmpty { listOf("Inbox") }.joinToString(", ")
            text.append("[${index + 1}] «${passage.title}» (${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(passage.date))}, $place)\n${passage.text}\n\n")
        }
        return text.append("Question: ").append(question).toString()
    }

    /** Die Notizen hinter den Passagen, die die Antwort als [n] nennt; die besten Treffer, wenn sie keine nennt. */
    fun sources(answer: String, passages: List<Passage>): List<ChatSource> {
        val numbers = Regex("""\[([0-9, ]+)]""").findAll(answer).flatMap { match -> match.groupValues[1].split(',', ' ').mapNotNull { it.trim().toIntOrNull() } }.toList()
        var indices = numbers.filter { it in 1..passages.size }.map { it - 1 }
        if (indices.isEmpty()) indices = passages.indices.take(3)
        val seen = HashSet<String>()
        return indices.mapNotNull { index -> passages[index].takeIf { seen.add(it.noteID) }?.let { ChatSource(it.noteID, it.title, it.date) } }
    }
}

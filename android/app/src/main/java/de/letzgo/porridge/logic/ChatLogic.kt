package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ChatSource
import de.letzgo.porridge.model.Note
import java.text.DateFormat
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
        val words = NoteChunks.tokens(question).toSet()
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
        var used = 0
        for (index in pool.indices.filter { scores[it] > 0 }.sortedByDescending { scores[it] }) {
            val passage = passage(pool[index], notes) ?: continue
            if (used + passage.text.length > budget && picked.isNotEmpty()) break
            picked += passage
            used += passage.text.length
            if (picked.size >= 10) break
        }
        return picked
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

    fun system(bucket: String?): String =
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

package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import kotlinx.serialization.Serializable
import java.text.BreakIterator
import java.util.Locale
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * iOS: `ChatChunk` (Services/ChunkRanking.swift) — eine Passage einer Notiz oder eines Transkripts, die der
 * Chat zitieren kann. Liegt im Index (`index/NoteIndex.kt`) mit Wortstatistik und, sobald berechnet, Satzvektor.
 */
@Serializable
data class ChatChunk(
    val noteID: String,
    val title: String,
    val date: Long,
    val text: String,
    val frequencies: Map<String, Int>,
    val prefixFrequencies: Map<String, Int>,
    val length: Int,
    /** Normierter Satzvektor (`ml/TextEmbedder`); null, bis er berechnet ist. */
    val embedding: FloatArray? = null,
) {
    override fun equals(other: Any?) = other is ChatChunk && other.noteID == noteID && other.text == text && other.date == date &&
        (other.embedding?.contentEquals(embedding) ?: (embedding == null))
    override fun hashCode() = 31 * noteID.hashCode() + text.hashCode()
}

/**
 * iOS: `ChatRetrieval` (Services/ChunkRanking.swift + ChatService.swift) — schneidet Notizen in Passagen und
 * ordnet sie für eine Frage: nach Wörtern (BM25) und, wenn die Passagen Vektoren haben, nach Bedeutung.
 */
object ChatRetrieval {
    const val CHUNK_SIZE = 700

    /**
     * Wörter in Kleinbuchstaben, mindestens zwei Zeichen, wie iOS `NLTokenizer(unit: .word)`: getrennt wird an
     * Leerraum, Satzzeichen, Bindestrich, Unterstrich und Doppelpunkt; Apostroph („hab's“) und Punkte zwischen
     * Ziffern („3.5“, „12.10.2026“) bleiben im Wort. `BreakIterator` liefert die Grobteilung, der Rest folgt hier.
     */
    fun tokens(text: String): List<String> {
        val iterator = BreakIterator.getWordInstance(Locale.ROOT)
        iterator.setText(text)
        val result = mutableListOf<String>()
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            val piece = text.substring(start, end)
            if (piece.any { it.isLetterOrDigit() }) {
                for (part in piece.split(splitter)) {
                    val word = part.trim('.', '\'').lowercase()
                    if (word.any { it.isLetterOrDigit() } && word.codePointCount(0, word.length) >= 2) result += word
                }
            }
            start = end
            end = iterator.next()
        }
        return result
    }

    /** Alles außer Buchstaben, Ziffern, Apostroph und Punkt trennt Wörter. */
    private val splitter = Regex("""[^\p{L}\p{N}'.]+""")

    fun prefix(token: String): String? =
        if (token.codePointCount(0, token.length) >= 5) token.substring(0, token.offsetByCodePoints(0, 5)) else null

    /** Wie oft `word` in einer Passage steht: genau, oder halb für ein Wort mit denselben ersten fünf Buchstaben. */
    fun frequency(word: String, chunk: ChatChunk): Double {
        val exact = (chunk.frequencies[word] ?: 0).toDouble()
        val key = prefix(word) ?: return exact
        return exact + 0.5 * (chunk.prefixFrequencies[key] ?: 0)
    }

    fun similarity(a: FloatArray, b: FloatArray): Float {
        if (a.size != b.size || a.isEmpty()) return 0f
        var sum = 0f
        for (i in a.indices) sum += a[i] * b[i]
        return sum
    }

    /**
     * Die Passagen, die am besten zu `query` passen, höchstens `budget` Zeichen und zehn Stück. Mit
     * `queryVector` zählt die Bedeutung mit: die Kosinusse dieses Embeddings sind nicht absolut, daher zählt
     * eine Passage allein durch Bedeutung nur, wenn sie für diese Frage deutlich heraussticht (z-Wert), und
     * unter den Passagen mit den Wörtern entscheidet die Bedeutung die Reihenfolge mit.
     */
    fun search(query: String, chunks: List<ChatChunk>, queryVector: FloatArray? = null, budget: Int = 6500): List<ChatChunk> {
        val words = tokens(query).toSet().toList()
        if (words.isEmpty() || chunks.isEmpty()) return emptyList()

        val average = chunks.sumOf { it.length }.toDouble() / chunks.size
        val count = chunks.size.toDouble()
        val scores = DoubleArray(chunks.size)
        for (word in words) {
            val containing = chunks.count { frequency(word, it) > 0 }
            if (containing == 0) continue
            val idf = ln(1 + (count - containing + 0.5) / (containing + 0.5))
            chunks.forEachIndexed { index, chunk ->
                val tf = frequency(word, chunk)
                if (tf <= 0) return@forEachIndexed
                val k1 = 1.4
                val b = 0.75
                scores[index] += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * chunk.length / max(average, 1.0)))
            }
        }

        if (queryVector != null) {
            val cosines = chunks.map { chunk -> chunk.embedding?.let { similarity(queryVector, it).toDouble() } }
            val known = cosines.filterNotNull()
            if (known.size >= 3) {
                val mean = known.sum() / known.size
                val deviation = max(sqrt(known.sumOf { (it - mean) * (it - mean) } / known.size), 0.001)
                val best = scores.maxOrNull() ?: 0.0
                for (index in chunks.indices) {
                    val lexical = if (best > 0) scores[index] / best else 0.0
                    val cosine = cosines[index]
                    if (cosine == null) {
                        scores[index] = lexical * 0.7
                        continue
                    }
                    val z = (cosine - mean) / deviation
                    // 0 beim Durchschnitt, 1 bei drei Standardabweichungen darüber.
                    val standing = min(1.0, max(0.0, z / 3))
                    scores[index] = when {
                        lexical > 0 -> 0.7 * lexical + 0.3 * standing
                        z >= 2.5 -> 0.3 * standing
                        else -> 0.0
                    }
                }
            }
        }

        val ranked = chunks.indices.filter { scores[it] > 0 }.sortedByDescending { scores[it] }
        val picked = mutableListOf<ChatChunk>()
        var used = 0
        for (index in ranked) {
            val chunk = chunks[index]
            if (used + chunk.text.length > budget && picked.isNotEmpty()) break
            picked += chunk
            used += chunk.text.length
            if (picked.size >= 10) break
        }
        return picked
    }

    /** Passt nichts („was war diese Woche?“), sind die neuesten Zusammenfassungen und Notizen der Kontext. */
    fun recent(chunks: List<ChatChunk>, budget: Int = 4500): List<ChatChunk> {
        val picked = mutableListOf<ChatChunk>()
        var used = 0
        for (chunk in chunks.sortedByDescending { it.date }) {
            if (used + chunk.text.length > budget && picked.isNotEmpty()) break
            picked += chunk
            used += chunk.text.length
            if (picked.size >= 8) break
        }
        return picked
    }

    private fun chunk(note: Note, text: String): ChatChunk {
        val words = tokens(note.displayTitle + " " + note.tags.joinToString(" ") + " " + text)
        val frequencies = HashMap<String, Int>()
        val prefixes = HashMap<String, Int>()
        for (word in words) {
            frequencies.merge(word, 1, Int::plus)
            prefix(word)?.let { prefixes.merge(it, 1, Int::plus) }
        }
        return ChatChunk(note.id, note.displayTitle, note.createdAt, text, frequencies, prefixes, max(words.size, 1))
    }

    /** Schneidet Text an Absätzen in Passagen von etwa [CHUNK_SIZE] Zeichen. */
    internal fun pieces(paragraphs: List<String>): List<String> {
        val result = mutableListOf<String>()
        var current = ""
        for (paragraph in paragraphs) {
            val text = paragraph.trim()
            if (text.isEmpty()) continue
            if (current.isNotEmpty() && current.length + text.length > CHUNK_SIZE) {
                result += current
                current = ""
            }
            current += (if (current.isEmpty()) "" else "\n") + text
        }
        if (current.isNotEmpty()) result += current
        return result
    }

    fun chunks(notes: List<Note>): List<ChatChunk> {
        val result = mutableListOf<ChatChunk>()
        for (note in notes) {
            if (note.isDeleted) continue
            // Ein gespeicherter Link ist über Adresse und Seite zu finden, auch wenn seine Seite nicht lesbar war.
            note.url?.takeIf { it.isNotEmpty() }?.let { url ->
                result += chunk(note, "Saved link" + (note.domain?.let { " ($it)" } ?: "") + ": " + url)
            }
            note.summary?.takeIf { it.isNotEmpty() }?.let { summary ->
                pieces(summary.split("\n")).forEach { result += chunk(note, "Summary: $it") }
            }
            pieces(note.text.split("\n")).forEach { result += chunk(note, it) }
            note.pageText?.takeIf { it.isNotEmpty() }?.let { page ->
                val label = "Article" + (note.domain?.let { " ($it)" } ?: "") + ": "
                pieces(page.split("\n")).forEach { result += chunk(note, label + it) }
            }
            val speakers = note.speakers
            val lines = note.segments.map { segment ->
                val name = segment.speakerId?.let { id -> speakers.firstOrNull { it.id == id }?.name }
                (name?.let { "$it: " } ?: "") + segment.text
            }
            pieces(lines).forEach { result += chunk(note, "Transcript: $it") }
        }
        return result
    }
}

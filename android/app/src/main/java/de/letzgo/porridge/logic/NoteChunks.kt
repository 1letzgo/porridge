package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import kotlinx.serialization.Serializable
import java.text.BreakIterator
import java.util.Locale

/** iOS: `NoteChunk` (Services/NoteChunks.swift) — eine Passage einer Notiz oder eines Transkripts mit ihrer Wortstatistik. Liegt im Index (`index/NoteIndex.kt`). */
@Serializable
data class NoteChunk(
    val noteID: String,
    val text: String,
    val frequencies: Map<String, Int>,
    val prefixFrequencies: Map<String, Int>,
)

/** iOS: `NoteChunks` (Services/NoteChunks.swift) — schneidet Notizen in Passagen und sagt, ob ein Wort darin steht. */
object NoteChunks {
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
    fun frequency(word: String, chunk: NoteChunk): Double {
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

    private fun chunk(note: Note, text: String): NoteChunk {
        val words = tokens(note.displayTitle + " " + note.tags.joinToString(" ") + " " + text)
        val frequencies = HashMap<String, Int>()
        val prefixes = HashMap<String, Int>()
        for (word in words) {
            frequencies.merge(word, 1, Int::plus)
            prefix(word)?.let { prefixes.merge(it, 1, Int::plus) }
        }
        return NoteChunk(note.id, text, frequencies, prefixes)
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

    fun chunks(notes: List<Note>): List<NoteChunk> {
        val result = mutableListOf<NoteChunk>()
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

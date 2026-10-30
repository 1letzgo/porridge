package de.letzgo.porridge.model

/** iOS: `NoteText` (Models/Note.swift) — Hilfen rund um den Markdown-Text einer Notiz, ohne UI. */
object NoteText {
    private val tagRegex = Regex("""(?<![\p{L}\p{N}_&#/])#([\p{L}\p{N}_][\p{L}\p{N}_-]*)""")
    private val marks = Regex("""^\s*(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]]\s+|[-*+]\s+|\d+\.\s+)""")

    /** Wo die Tags (`#wort`) in einer Zeile stehen. */
    fun tagRanges(line: String): List<IntRange> =
        if ('#' !in line) emptyList() else tagRegex.findAll(line).map { it.range }.toList()

    /** Tags (`#wort`) in Reihenfolge, ohne Doppelte (Groß/klein egal); nicht in Code-Blöcken. */
    fun tags(text: String): List<String> {
        if ('#' !in text) return emptyList()
        val seen = HashSet<String>()
        val result = mutableListOf<String>()
        var inFence = false
        for (line in text.split("\n")) {
            if (line.startsWith("```")) { inFence = !inFence; continue }
            if (inFence || '#' !in line) continue
            for (match in tagRegex.findAll(line)) {
                val tag = match.groupValues[1]
                if (seen.add(tag.lowercase())) result += tag
            }
        }
        return result
    }

    /** Nicht-leere Zeilen ohne Block-Zeichen (`# `, `- [ ] `, `1. `, `> `) und Inline-Zeichen (`**`, `*`, `~~`, `` ` ``). */
    fun plainLines(text: String): List<String> = text.split("\n").mapNotNull { raw ->
        if (raw.isEmpty() || raw.startsWith("```")) return@mapNotNull null
        var line = marks.find(raw)?.let { raw.removeRange(it.range) } ?: raw
        for (mark in listOf("**", "~~", "`", "*")) line = line.replace(mark, "")
        line = line.trim(' ', '\t')
        line.ifEmpty { null }
    }
}

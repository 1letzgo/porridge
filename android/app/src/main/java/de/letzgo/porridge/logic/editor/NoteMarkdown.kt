package de.letzgo.porridge.logic.editor

import de.letzgo.porridge.logic.editor.NoteBlock.Kind

/**
 * iOS: `NoteMarkdown` (Views/Notes/NoteMarkdown.swift), ohne Schriften und Farben — die Notiz als Text mit
 * Zeichenattributen für den Editor und zurück zu Markdown. Jeder Absatz trägt seine Art als Attribut; Listen haben
 * ihr Zeichen als Text am Absatzanfang („•“ oder „1.“ und ein Tab), eine Checkliste beginnt mit einem
 * Checkbox-Zeichen. Fett und kursiv sind Merkmale der Zeichen.
 */
object NoteMarkdown {
    /** Das Zeichen, das die Checkbox trägt (iOS: `NSTextAttachment`, U+FFFC). */
    const val CHECKBOX = "￼"

    fun paragraphStyle(kind: Kind, indent: Int): CharStyle = CharStyle(block = blockName(kind), indent = if (kind.isList) indent else 0)

    private fun blockName(kind: Kind): String? = when (kind) {
        is Kind.Heading -> "h${kind.level}"
        Kind.Quote -> "quote"
        Kind.Bullet -> "bullet"
        Kind.Numbered -> "numbered"
        is Kind.Checklist -> "checklist"
        Kind.Paragraph -> null
    }

    /** iOS: `kind(of:)` — Art und Einrückung aus den Attributen des ersten Zeichens. */
    fun kind(style: CharStyle): Pair<Kind, Int> = when (style.block) {
        "h1" -> Kind.Heading(1) to 0
        "h2" -> Kind.Heading(2) to 0
        "h3" -> Kind.Heading(3) to 0
        "quote" -> Kind.Quote to 0
        "bullet" -> Kind.Bullet to style.indent
        "numbered" -> Kind.Numbered to style.indent
        "checklist" -> Kind.Checklist(style.checked) to style.indent
        else -> Kind.Paragraph to 0
    }

    // Markdown → Puffer

    fun styled(markdown: String): List<StyledText> {
        val result = mutableListOf<StyledText>()
        val lines = markdown.split("\n")
        val counters = mutableMapOf<Int, Int>()
        lines.forEachIndexed { i, line ->
            val block = NoteBlock.parseLine(line)
            val number = next(counters, block.kind, block.indent)
            val paragraph = paragraphStyle(block.kind, block.indent)
            val pieces = mutableListOf<StyledText>()
            pieces += marker(block.kind, number).map { it.copy(style = it.style.copy(block = paragraph.block, indent = paragraph.indent)) }
            pieces += inline(block.text).map { (text, bold, italic) -> StyledText(text, paragraph.copy(bold = bold, italic = italic)) }
            if (i < lines.size - 1) pieces += StyledText("\n", paragraph)
            result += pieces
        }
        return result
    }

    /** Nummerierung: Einträge einer Ebene zählen weiter; ein Absatz, der kein nummerierter Eintrag dieser Ebene ist, beendet sie. */
    fun next(counters: MutableMap<Int, Int>, kind: Kind, indent: Int): Int {
        if (kind == Kind.Numbered) {
            counters.keys.removeAll { it > indent }
            return counters.merge(indent, 1, Int::plus)!!
        }
        if (kind.isList) counters.keys.removeAll { it >= indent } else counters.clear()
        return 0
    }

    /** Was vor dem Text eines Absatzes steht: das Listenzeichen, die Checkbox oder nichts. */
    fun marker(kind: Kind, number: Int): List<StyledText> = when (kind) {
        Kind.Bullet -> listOf(StyledText("•\t", CharStyle(marker = true)))
        Kind.Numbered -> listOf(StyledText("${maxOf(1, number)}.\t", CharStyle(marker = true)))
        is Kind.Checklist -> listOf(StyledText(CHECKBOX, CharStyle(checkbox = true, checked = kind.checked, marker = true)))
        else -> emptyList()
    }

    /** Fett (`**`) und kursiv (`*`) einer Zeile; Zeichen sind nur paarweise Zeichen, sonst Text. */
    fun inline(text: String): List<Triple<String, Boolean, Boolean>> {
        val result = mutableListOf<Triple<String, Boolean, Boolean>>()
        val strong = text.split("**").size - 1
        val emphasis = text.split("*").size - 1 - 2 * strong
        val strongPairs = strong % 2 == 0 && strong > 0
        val emphasisPairs = emphasis % 2 == 0 && emphasis > 0
        var bold = false
        var italic = false
        val run = StringBuilder()
        fun flush() {
            if (run.isEmpty()) return
            result += Triple(run.toString(), bold, italic)
            run.clear()
        }
        var i = 0
        while (i < text.length) {
            if (strongPairs && text[i] == '*' && i + 1 < text.length && text[i + 1] == '*') {
                flush(); bold = !bold; i += 2
            } else if (emphasisPairs && text[i] == '*') {
                flush(); italic = !italic; i += 1
            } else {
                run.append(text[i]); i += 1
            }
        }
        flush()
        return result
    }

    // Puffer → Markdown

    /** Der Absatz (mit Zeilenumbruch) um `location`, wie `NSString.paragraphRange`. */
    fun paragraphRange(text: CharSequence, location: Int): IntRange {
        val at = location.coerceIn(0, text.length)
        var start = at
        while (start > 0 && text[start - 1] != '\n') start--
        var end = at
        while (end < text.length && text[end] != '\n') end++
        if (end < text.length) end++
        return start until end
    }

    fun markerLength(buffer: EditorBuffer, paragraph: IntRange): Int {
        if (paragraph.isEmpty()) return 0
        val (kind, _) = kind(buffer.style(paragraph.first))
        return when (kind) {
            Kind.Bullet, Kind.Numbered -> {
                val tab = (paragraph).firstOrNull { buffer.text[it] == '\t' } ?: return 0
                tab - paragraph.first + 1
            }
            is Kind.Checklist -> if (buffer.style(paragraph.first).checkbox) 1 else 0
            else -> 0
        }
    }

    fun markdown(buffer: EditorBuffer): String {
        val text = buffer.text
        val lines = mutableListOf<String>()
        val counters = mutableMapOf<Int, Int>()
        var location = 0
        while (location < text.length) {
            val range = paragraphRange(text, location)
            var contentEnd = range.last + 1
            if (text[range.last] == '\n') contentEnd--
            val (kind, indent) = kind(buffer.style(range.first))
            val marker = markerLength(buffer, range)
            val start = minOf(range.first + marker, contentEnd)
            val block = NoteBlock(kind, indent, inlineMarkdown(buffer, start, contentEnd, kind))
            val number = next(counters, kind, indent)
            lines += block.mark(number) + block.text
            location = range.last + 1
        }
        // Ein Text, der mit einem Zeilenumbruch endet, hat noch einen leeren Absatz.
        if (text.isEmpty() || text[text.length - 1] == '\n') lines += ""
        return lines.joinToString("\n")
    }

    /** Der Text eines Absatzes mit `**` und `*` um fette und kursive Läufe. */
    fun inlineMarkdown(buffer: EditorBuffer, start: Int, end: Int, kind: Kind): String {
        val out = StringBuilder()
        var bold = false
        var italic = false
        val headingBold = kind is Kind.Heading
        var i = start
        while (i < end) {
            val style = buffer.style(i)
            var j = i + 1
            while (j < end && buffer.style(j).let { it.bold == style.bold && it.italic == style.italic && it.checkbox == style.checkbox }) j++
            if (style.checkbox) { i = j; continue }
            val text = buffer.text.subSequence(i, j).toString()
            val runBold = !headingBold && style.bold
            val runItalic = style.italic
            // Zeichen um Leerraum sind in Markdown keine Zeichen: nach dem Leerraum öffnen, davor schließen.
            if (text.all { it.isWhitespace() }) {
                if (italic) { out.append("*"); italic = false }
                if (bold) { out.append("**"); bold = false }
                out.append(text)
            } else {
                if (italic != runItalic || bold != runBold) {
                    if (italic) { out.append("*"); italic = false }
                    if (bold) { out.append("**"); bold = false }
                }
                if (runBold && !bold) { out.append("**"); bold = true }
                if (runItalic && !italic) { out.append("*"); italic = true }
                out.append(text)
            }
            i = j
        }
        if (italic) out.append("*")
        if (bold) out.append("**")
        return out.toString()
    }
}

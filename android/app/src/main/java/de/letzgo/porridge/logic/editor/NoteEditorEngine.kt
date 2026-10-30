package de.letzgo.porridge.logic.editor

import de.letzgo.porridge.logic.editor.NoteBlock.Kind

/** iOS: `NoteEditorCommand` — was Formatleiste und Notizbildschirm vom Editor verlangen. */
sealed interface NoteEditorCommand {
    /** Macht die Absätze der Auswahl zu dieser Art; dieselbe Art noch einmal macht sie wieder zu Text. */
    data class SetKind(val kind: Kind) : NoteEditorCommand
    /** Rückt Listeneinträge ein (`deeper`) oder aus. */
    data class Shift(val deeper: Boolean) : NoteEditorCommand
    /** Fett (`**`) oder kursiv (`*`) um die Auswahl oder das Wort am Cursor; noch einmal entfernt es. */
    data class ToggleInline(val mark: String) : NoteEditorCommand
}

/**
 * iOS: die Bearbeitungslogik von `NoteTextCoordinator` (Views/Notes/NoteTextView.swift), ohne Plattform: Return und
 * Backspace kennen Listen und Checklisten, „- “ oder „# “ am Zeilenanfang macht die Zeile zu dieser Art, Tab rückt
 * ein, Nummern zählen mit. Arbeitet auf einem [EditorBuffer]; [onCommit] bekommt danach das Markdown.
 */
class NoteEditorEngine(private val buffer: EditorBuffer, private val onCommit: (String) -> Unit = {}) {
    /** Der Editor ändert den Text selbst (Zeichen, Nummern): keine Regeln, kein Speichern. */
    var isAdjusting = false
        private set

    private val text get() = buffer.text

    fun load(markdown: String) {
        isAdjusting = true
        buffer.replace(0, buffer.length, NoteMarkdown.styled(markdown))
        isAdjusting = false
        buffer.selectionStart = buffer.length
        buffer.selectionEnd = buffer.length
        resetTypingAttributes()
    }

    fun markdown(): String = NoteMarkdown.markdown(buffer)

    fun commit() = onCommit(markdown())

    // Absätze

    fun paragraphRange(location: Int): IntRange = NoteMarkdown.paragraphRange(text, location)

    /** Der Absatz ohne Zeilenumbruch. */
    private fun contentEnd(paragraph: IntRange): Int =
        if (!paragraph.isEmpty() && text[paragraph.last] == '\n') paragraph.last else paragraph.last + 1

    fun kind(paragraph: IntRange): Pair<Kind, Int> =
        // Ein leerer letzter Absatz hat keine Zeichen: seine Art ist die, die getippt würde.
        if (paragraph.isEmpty()) NoteMarkdown.kind(buffer.typingStyle) else NoteMarkdown.kind(buffer.style(paragraph.first))

    private fun markerLength(paragraph: IntRange) = NoteMarkdown.markerLength(buffer, paragraph)

    /** Wo der Text eines Absatzes beginnt (nach Zeichen oder Checkbox). */
    fun textStart(paragraph: IntRange) = paragraph.first + markerLength(paragraph)

    private fun selectedParagraphs(): List<IntRange> {
        val ranges = mutableListOf<IntRange>()
        var location = buffer.selectionStart
        do {
            val paragraph = paragraphRange(location)
            ranges += paragraph
            location = paragraph.first + maxOf(paragraph.count(), 1)
        } while (location < buffer.selectionEnd)
        return ranges
    }

    private fun IntRange.len() = if (isEmpty()) 0 else last - first + 1

    /** Gibt einem Absatz Art und Einrückung: Zeichen und Absatzattribute. Liefert den neuen Bereich. */
    fun restyle(paragraph: IntRange, kind: Kind, indent: Int): IntRange {
        val selStart = buffer.selectionStart
        val selLength = buffer.selectionEnd - buffer.selectionStart
        isAdjusting = true
        // Das Zeichen der alten Art geht, das der neuen kommt.
        val oldMarker = markerLength(paragraph)
        val marker = NoteMarkdown.marker(kind, 1)
        val markerLength = marker.sumOf { it.text.length }
        val start = paragraph.first
        buffer.replace(start, start + oldMarker, marker)
        val newLength = paragraph.len() + markerLength - oldMarker
        val range = start until start + newLength
        val paragraphStyle = NoteMarkdown.paragraphStyle(kind, indent)
        buffer.restyle(range.first, range.first + newLength) { it.copy(block = paragraphStyle.block, indent = paragraphStyle.indent) }
        isAdjusting = false
        // Der Cursor behält seinen Platz im Text; nie im Zeichen.
        if (selStart >= start) {
            val shifted = selStart + if (selStart >= start + oldMarker) markerLength - oldMarker else 0
            val location = maxOf(start + markerLength, minOf(shifted, buffer.length))
            buffer.selectionStart = location
            buffer.selectionEnd = minOf(location + selLength, buffer.length)
        }
        if (kind == Kind.Numbered) renumber()
        resetTypingAttributes()
        if (newLength == 0) {
            // Keine Zeichen, die die Art tragen: was als Nächstes getippt wird, bekommt sie. Nach dem Zurücksetzen,
            // denn der Cursor kann noch im Absatz davor stehen (Return nach einer Überschrift).
            buffer.typingStyle = paragraphStyle
        }
        return range
    }

    /** Nummerierte Einträge zählen ab dem vorigen weiter; die Zeichen im Text werden angeglichen. */
    private fun renumber() {
        val counters = mutableMapOf<Int, Int>()
        var location = 0
        var selection = buffer.selectionStart
        isAdjusting = true
        while (location < buffer.length) {
            val paragraph = paragraphRange(location)
            val (kind, indent) = kind(paragraph)
            val number = NoteMarkdown.next(counters, kind, indent)
            var length = paragraph.len()
            if (kind == Kind.Numbered) {
                val old = markerLength(paragraph)
                val marker = NoteMarkdown.marker(Kind.Numbered, number)
                val markerText = marker.joinToString("") { it.text }
                if (text.subSequence(paragraph.first, paragraph.first + old).toString() != markerText) {
                    val style = NoteMarkdown.paragraphStyle(Kind.Numbered, indent)
                    buffer.replace(paragraph.first, paragraph.first + old, marker.map { it.copy(style = it.style.copy(block = style.block, indent = style.indent)) })
                    val delta = markerText.length - old
                    length += delta
                    if (selection >= paragraph.first + old) selection += delta
                }
            }
            location = paragraph.first + maxOf(length, 1)
        }
        isAdjusting = false
        if (selection != buffer.selectionStart) {
            val selLength = buffer.selectionEnd - buffer.selectionStart
            buffer.selectionStart = selection
            buffer.selectionEnd = minOf(selection + selLength, buffer.length)
        }
    }

    /** Tippattribute aus dem Absatz am Cursor, nie die der Checkbox selbst. Ein leerer Absatz behält seine. */
    fun resetTypingAttributes() {
        val paragraph = paragraphRange(buffer.selectionStart)
        val contentEnd = contentEnd(paragraph)
        val contentLength = if (paragraph.isEmpty()) 0 else contentEnd - paragraph.first
        val start = textStart(paragraph)
        buffer.typingStyle = when {
            contentLength > markerLength(paragraph) -> {
                // Das Zeichen vor dem Cursor trägt den Lauf (fett bleibt fett); am Textanfang das erste.
                val at = minOf(maxOf(start, buffer.selectionStart), contentEnd)
                val index = maxOf(start, minOf(at - 1, buffer.length - 1))
                buffer.style(minOf(index, buffer.length - 1))
            }
            !paragraph.isEmpty() -> {
                val (kind, indent) = kind(paragraph)
                NoteMarkdown.paragraphStyle(kind, indent)
            }
            else -> buffer.typingStyle
        }.forTyping()
    }

    // Regeln

    /**
     * Return, Backspace und Tab mit ihrer Bedeutung in Listen. `true` lässt die Änderung normal geschehen;
     * `false` heißt, die Engine hat sie selbst ausgeführt (oder verworfen).
     */
    fun shouldChange(start: Int, end: Int, replacement: String): Boolean {
        if (isAdjusting) return true
        val paragraph = paragraphRange(start)
        val (kind, indent) = kind(paragraph)
        val contentEnd = contentEnd(paragraph)
        val textStart = textStart(paragraph)
        val textLength = maxOf(0, contentEnd - textStart)
        val length = end - start

        if (replacement == "\n" && length == 0) {
            when {
                kind.isList -> {
                    if (textLength == 0) {
                        // Return auf einem leeren Eintrag beendet die Liste, Ebene für Ebene.
                        if (indent > 0) restyle(paragraph, kind, indent - 1) else restyle(paragraph, Kind.Paragraph, 0)
                        commit()
                        return false
                    }
                    // Die nächste Zeile ist ein Eintrag derselben Art (eine Checkliste beginnt unabgehakt).
                    val next = if (kind is Kind.Checklist) Kind.Checklist(false) else kind
                    val style = NoteMarkdown.paragraphStyle(next, indent)
                    val pieces = listOf(StyledText("\n", buffer.typingStyle)) + NoteMarkdown.marker(next, 1)
                    val styled = pieces.map { it.copy(style = it.style.copy(block = style.block, indent = style.indent)) }
                    isAdjusting = true
                    buffer.replace(start, end, styled)
                    isAdjusting = false
                    val location = start + styled.sumOf { it.text.length }
                    buffer.selectionStart = location
                    buffer.selectionEnd = location
                    if (kind == Kind.Numbered) renumber()
                    resetTypingAttributes()
                    commit()
                    return false
                }
                kind is Kind.Heading || kind == Kind.Quote -> {
                    // Die Zeile nach einer Überschrift oder einem Zitat ist Text.
                    isAdjusting = true
                    buffer.replace(start, end, listOf(StyledText("\n", buffer.typingStyle)))
                    isAdjusting = false
                    restyle(paragraphRange(start + 1), Kind.Paragraph, 0)
                    buffer.selectionStart = start + 1
                    buffer.selectionEnd = start + 1
                    resetTypingAttributes()
                    commit()
                    return false
                }
                else -> return true
            }
        }

        if (replacement.isEmpty() && length == 1) {
            // Backspace ins Zeichen: erst geht das Zeichen, erst dann verbindet sich die Zeile mit der davor.
            if (kind.isList && start == textStart - 1) {
                if (indent > 0) restyle(paragraph, kind, indent - 1) else restyle(paragraph, Kind.Paragraph, 0)
                commit()
                return false
            }
            if ((kind == Kind.Quote || kind.headingLevel > 0) && start == paragraph.first - 1) {
                restyle(paragraph, Kind.Paragraph, 0)
                buffer.selectionStart = paragraph.first
                buffer.selectionEnd = paragraph.first
                commit()
                return false
            }
        }

        if (replacement == "\t") {
            if (kind.isList) shift(deeper = true)
            return false
        }

        // In ein Zeichen wird nichts getippt.
        if (start < textStart && length == 0 && replacement.isNotEmpty()) {
            isAdjusting = true
            buffer.replace(textStart, textStart, listOf(StyledText(replacement, buffer.typingStyle)))
            isAdjusting = false
            buffer.selectionStart = textStart + replacement.length
            buffer.selectionEnd = buffer.selectionStart
            didChange()
            return false
        }
        return true
    }

    /**
     * Ob [shouldChange] diese Änderung selbst ausführen (oder verwerfen) würde — ohne etwas zu ändern. Auf Android
     * fängt der Editor nur diese Fälle ab; alles andere tippt die Tastatur selbst (die Komposition bleibt heil).
     */
    fun intercepts(start: Int, end: Int, replacement: String): Boolean {
        if (isAdjusting) return false
        val paragraph = paragraphRange(start)
        val (kind, _) = kind(paragraph)
        val textStart = textStart(paragraph)
        val length = end - start
        return when {
            replacement == "\n" && length == 0 -> kind.isList || kind is Kind.Heading || kind == Kind.Quote
            replacement.isEmpty() && length == 1 ->
                (kind.isList && start == textStart - 1) || ((kind == Kind.Quote || kind.headingLevel > 0) && start == paragraph.first - 1)
            replacement == "\t" -> true
            else -> start < textStart && length == 0 && replacement.isNotEmpty()
        }
    }

    /** Nach einer Änderung: „- “, „1. “, „[] “, „# “ oder „> “ am Zeilenanfang macht die Zeile zu dieser Art. */
    fun didChange() {
        if (isAdjusting) return
        var paragraph = paragraphRange(buffer.selectionStart)
        var (kind, _) = kind(paragraph)
        if (kind.isList && markerLength(paragraph) == 0) {
            // Das Zeichen wurde gelöscht (Auswahl darüber hinweg): die Zeile ist wieder Text.
            paragraph = restyle(paragraph, Kind.Paragraph, 0)
            kind = Kind.Paragraph
        }
        if (kind == Kind.Paragraph && !paragraph.isEmpty()) {
            val contentEnd = contentEnd(paragraph)
            val line = text.subSequence(paragraph.first, contentEnd).toString()
            val typed = buffer.selectionStart - paragraph.first
            val converted = shortcut(line)
            if (typed == line.length && converted != null) {
                isAdjusting = true
                buffer.replace(paragraph.first, contentEnd, emptyList())
                isAdjusting = false
                buffer.selectionStart = paragraph.first
                buffer.selectionEnd = paragraph.first
                restyle(paragraphRange(paragraph.first), converted, 0)
                commit()
                return
            }
        }
        renumberIfNeeded()
        commit()
    }

    private fun renumberIfNeeded() {
        if ((0 until buffer.length).any { buffer.style(it).block == "numbered" }) renumber()
    }

    /** Der Cursor steht nie in einem Zeichen oder vor einer Checkbox. */
    fun selectionChanged() {
        if (isAdjusting) return
        if (buffer.selectionStart == buffer.selectionEnd) {
            val start = textStart(paragraphRange(buffer.selectionStart))
            if (buffer.selectionStart < start) {
                buffer.selectionStart = start
                buffer.selectionEnd = start
                return
            }
        }
        resetTypingAttributes()
    }

    /** Ein Tipp auf eine Checkbox hakt sie ab. */
    fun toggleCheckbox(index: Int): Boolean {
        for (candidate in listOf(index, index - 1)) {
            if (candidate < 0 || candidate >= buffer.length || !buffer.style(candidate).checkbox) continue
            val checked = buffer.style(candidate).checked
            val paragraph = paragraphRange(candidate)
            val (_, indent) = kind(paragraph)
            restyle(paragraph, Kind.Checklist(!checked), indent)
            commit()
            return true
        }
        return false
    }

    fun perform(command: NoteEditorCommand) {
        when (command) {
            is NoteEditorCommand.SetKind -> {
                for (paragraph in selectedParagraphs().reversed()) {
                    val (current, indent) = kind(paragraph)
                    val same = current == command.kind || (command.kind is Kind.Checklist && current is Kind.Checklist)
                    val next = if (same) Kind.Paragraph else command.kind
                    restyle(paragraph, next, if (next.isList) indent else 0)
                }
                renumberIfNeeded()
                selectionChanged()
            }
            is NoteEditorCommand.Shift -> shift(command.deeper)
            is NoteEditorCommand.ToggleInline -> toggleInline(command.mark)
        }
        commit()
    }

    private fun shift(deeper: Boolean) {
        for (paragraph in selectedParagraphs().reversed()) {
            val (kind, indent) = kind(paragraph)
            if (!kind.isList) continue
            val next = (indent + if (deeper) 1 else -1).coerceIn(0, NoteBlock.MAX_INDENT)
            if (next != indent) restyle(paragraph, kind, next)
        }
        renumberIfNeeded()
        commit()
    }

    private fun toggleInline(mark: String) {
        var start = buffer.selectionStart
        var end = buffer.selectionEnd
        if (start == end) {
            // Das Wort am Cursor.
            val paragraphStart = textStart(paragraphRange(start))
            fun isWord(at: Int) = at >= paragraphStart && at < buffer.length && text[at].isLetterOrDigit()
            while (isWord(start - 1)) start--
            while (isWord(end)) end++
        }
        val bold = mark == "**"
        if (start == end) {
            // Nichts zu umschließen: was als Nächstes getippt wird, bekommt das Merkmal.
            val typing = buffer.typingStyle
            buffer.typingStyle = if (bold) typing.copy(bold = !typing.bold) else typing.copy(italic = !typing.italic)
            return
        }
        // An, wenn alle Läufe das Merkmal haben; dann wird es genommen, sonst allen gegeben.
        val allOn = (start until end).all { buffer.style(it).let { s -> if (bold) s.bold else s.italic } }
        isAdjusting = true
        buffer.restyle(start, end) { style ->
            if (style.checkbox) style else if (bold) style.copy(bold = !allOn) else style.copy(italic = !allOn)
        }
        isAdjusting = false
        buffer.selectionStart = start
        buffer.selectionEnd = end
    }

    companion object {
        fun shortcut(value: String): Kind? = when (value) {
            "- ", "* ", "• " -> Kind.Bullet
            "[] ", "- [ ] " -> Kind.Checklist(false)
            "# " -> Kind.Heading(1)
            "## " -> Kind.Heading(2)
            "### " -> Kind.Heading(3)
            "> " -> Kind.Quote
            else -> if (value.length >= 3 && value.endsWith(". ") && value.dropLast(2).all { it.isDigit() }) Kind.Numbered else null
        }
    }
}

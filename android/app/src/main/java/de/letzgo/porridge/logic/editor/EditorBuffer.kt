package de.letzgo.porridge.logic.editor

/**
 * Die Attribute eines Zeichens im Editor — das, was auf iOS am `NSAttributedString` hängt
 * (`.noteBlock`, `.noteIndent`, `.noteChecked`, Schriftmerkmale, Checkbox-Anhang).
 * Absatzart und Einrückung gelten für den Absatz, in dem das erste Zeichen sie trägt.
 */
data class CharStyle(
    /** "h1", "h2", "h3", "quote", "bullet", "numbered", "checklist" oder null für einen einfachen Absatz. */
    val block: String? = null,
    val indent: Int = 0,
    val bold: Boolean = false,
    val italic: Boolean = false,
    /** Das Zeichen ist die Checkbox einer Checklisten-Zeile (iOS: Text-Anhang). */
    val checkbox: Boolean = false,
    /** Auf der Checkbox: abgehakt. */
    val checked: Boolean = false,
    /** Teil des Listenzeichens („•⇥“, „1.⇥“) — nur für die Darstellung. */
    val marker: Boolean = false,
) {
    /** Ohne Anhang, Haken und Marker (iOS: `resetTypingAttributes` entfernt `.attachment`, `.noteChecked`, `.kern`). */
    fun forTyping() = copy(checkbox = false, checked = false, marker = false)
}

/** Ein Stück Text mit einem Stil, zum Einfügen. */
data class StyledText(val text: String, val style: CharStyle)

/**
 * Der Text des Editors mit Zeichenattributen. Auf Android hinter einem `Editable` mit Spans
 * (`ui/notes/NoteTextEditor.kt`), in Tests im Speicher ([MemoryBuffer]). Positionen in UTF-16-Einheiten wie NSString.
 */
interface EditorBuffer {
    val text: CharSequence
    val length: Int get() = text.length
    fun style(at: Int): CharStyle
    /** Ersetzt `[start, end)` durch die Stücke. */
    fun replace(start: Int, end: Int, pieces: List<StyledText>)
    /** Ändert die Attribute in `[start, end)`. */
    fun restyle(start: Int, end: Int, transform: (CharStyle) -> CharStyle)
    var selectionStart: Int
    var selectionEnd: Int
    /** Was als Nächstes getippt wird (iOS: `typingAttributes`). */
    var typingStyle: CharStyle
}

/** Ein [EditorBuffer] im Speicher: Text plus ein Stil je Zeichen. */
class MemoryBuffer(initial: List<StyledText> = emptyList()) : EditorBuffer {
    private val chars = StringBuilder()
    private val styles = ArrayList<CharStyle>()

    init { replace(0, 0, initial) }

    override val text: CharSequence get() = chars
    override fun style(at: Int): CharStyle = styles[at]

    override fun replace(start: Int, end: Int, pieces: List<StyledText>) {
        chars.delete(start, end)
        repeat(end - start) { styles.removeAt(start) }
        var at = start
        for (piece in pieces) {
            chars.insert(at, piece.text)
            repeat(piece.text.length) { styles.add(at + it, piece.style) }
            at += piece.text.length
        }
    }

    override fun restyle(start: Int, end: Int, transform: (CharStyle) -> CharStyle) {
        for (i in start until end) styles[i] = transform(styles[i])
    }

    override var selectionStart = 0
    override var selectionEnd = 0
    override var typingStyle = CharStyle()
}

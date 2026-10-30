package de.letzgo.porridge.ui.notes

import android.text.Editable
import android.text.Selection
import android.text.Spanned
import de.letzgo.porridge.logic.editor.CharStyle
import de.letzgo.porridge.logic.editor.EditorBuffer
import de.letzgo.porridge.logic.editor.StyledText

/** Trägt den [CharStyle] eines Zeichenlaufs (iOS: die Attribute am `NSAttributedString`). */
class CharStyleSpan(val style: CharStyle)

/**
 * [EditorBuffer] über dem `Editable` eines `EditText`: der Text ist der des Feldes, der Stil liegt als [CharStyleSpan]
 * auf Läufen gleichen Stils. Die Darstellung (Größen, Einzüge, Checkboxen) setzt `NoteEditText.render` daraus.
 */
class EditableBuffer(private val editable: Editable) : EditorBuffer {
    override val text: CharSequence get() = editable
    override var typingStyle = CharStyle()

    override fun style(at: Int): CharStyle {
        val spans = editable.getSpans(at, at + 1, CharStyleSpan::class.java)
        return spans.lastOrNull { editable.getSpanStart(it) <= at && editable.getSpanEnd(it) > at }?.style ?: CharStyle()
    }

    override fun replace(start: Int, end: Int, pieces: List<StyledText>) {
        val text = pieces.joinToString("") { it.text }
        editable.replace(start, end, text)
        var at = start
        val styles = ArrayList<CharStyle>(text.length)
        for (piece in pieces) repeat(piece.text.length) { styles += piece.style }
        setStyles(at, styles)
        at += text.length
    }

    override fun restyle(start: Int, end: Int, transform: (CharStyle) -> CharStyle) {
        if (end <= start) return
        setStyles(start, (start until end).map { transform(style(it)) })
    }

    /** Setzt den Stil der Zeichen ab `start`; vorhandene Spans werden an den Grenzen geteilt. */
    fun setStyles(start: Int, styles: List<CharStyle>) {
        if (styles.isEmpty()) return
        val end = start + styles.size
        for (span in editable.getSpans(start, end, CharStyleSpan::class.java)) {
            val s = editable.getSpanStart(span)
            val e = editable.getSpanEnd(span)
            if (e <= start || s >= end) continue
            editable.removeSpan(span)
            if (s < start) editable.setSpan(CharStyleSpan(span.style), s, start, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (e > end) editable.setSpan(CharStyleSpan(span.style), end, e, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        var runStart = start
        for (i in 1..styles.size) {
            if (i == styles.size || styles[i] != styles[i - 1]) {
                editable.setSpan(CharStyleSpan(styles[i - 1]), runStart, start + i, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                runStart = start + i
            }
        }
    }

    override var selectionStart: Int
        get() = Selection.getSelectionStart(editable).coerceAtLeast(0)
        set(value) = Selection.setSelection(editable, value.coerceIn(0, editable.length), selectionEnd.coerceIn(value.coerceIn(0, editable.length), editable.length))

    override var selectionEnd: Int
        get() = Selection.getSelectionEnd(editable).coerceAtLeast(0)
        set(value) = Selection.setSelection(editable, selectionStart.coerceAtMost(value.coerceIn(0, editable.length)), value.coerceIn(0, editable.length))
}

package de.letzgo.porridge.ui.notes

import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatIndentDecrease
import androidx.compose.material.icons.automirrored.filled.FormatIndentIncrease
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.FormatBold
import androidx.compose.material.icons.filled.FormatItalic
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.Title
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import de.letzgo.porridge.logic.editor.NoteBlock.Kind
import de.letzgo.porridge.logic.editor.NoteEditorCommand
import de.letzgo.porridge.ui.Brand

/** iOS: `NoteEditorController` — lässt den Notizbildschirm in den Editor greifen: Cursor, Tastatur, Formate. */
class NoteEditorController {
    internal var view: NoteEditText? = null
    var isEditing by mutableStateOf(false)
        internal set

    /** Cursor als Zeichenposition im Markdown der Notiz; das Textende, wenn nicht bearbeitet wird. */
    val cursorOffset: Int
        get() {
            val v = view ?: return 0
            if (!v.hasFocus()) return v.lastWritten.length
            // Position im Feld → Position im Markdown: der Text bis zum Cursor als Markdown.
            return v.engine.markdown().length.coerceAtMost(markdownOffset(v))
        }

    private fun markdownOffset(v: NoteEditText): Int {
        val sel = v.selectionStart.coerceAtLeast(0)
        // Markdown des Texts vor dem Cursor; Zeichen und Marker zählen wie im Markdown.
        return de.letzgo.porridge.logic.editor.NoteMarkdown.markdown(PrefixBuffer(v, sel)).length
    }

    /** Fokus an den Textanfang mit Tastatur (Return im Titel). */
    fun focusStart() {
        val v = view ?: return
        v.requestFocus()
        v.setSelection(0)
        (v.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, 0)
    }

    fun blur() {
        val v = view ?: return
        v.clearFocus()
        (v.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(v.windowToken, 0)
    }

    fun perform(command: NoteEditorCommand) {
        val v = view ?: return
        v.engine.perform(command)
        v.render()
    }

    /** Die ersten `end` Zeichen des Feldes als eigener Puffer, um sie als Markdown zu zählen. */
    private class PrefixBuffer(private val v: NoteEditText, private val end: Int) : de.letzgo.porridge.logic.editor.EditorBuffer {
        private val inner = EditableBuffer(v.editableText)
        override val text: CharSequence get() = v.editableText.subSequence(0, end)
        override fun style(at: Int) = inner.style(at)
        override fun replace(start: Int, end: Int, pieces: List<de.letzgo.porridge.logic.editor.StyledText>) = Unit
        override fun restyle(start: Int, end: Int, transform: (de.letzgo.porridge.logic.editor.CharStyle) -> de.letzgo.porridge.logic.editor.CharStyle) = Unit
        override var selectionStart = 0
        override var selectionEnd = 0
        override var typingStyle = de.letzgo.porridge.logic.editor.CharStyle()
    }
}

/**
 * iOS: `NoteBodyEditor` — der Text einer Notiz mit Überschriften, Listen, Checklisten, fett und kursiv, als Markdown
 * gespeichert. Die Formatleiste steht über der Tastatur.
 */
@Composable
fun NoteBodyEditor(
    text: String,
    onTextChange: (String) -> Unit,
    controller: NoteEditorController,
    modifier: Modifier = Modifier,
    isEditable: Boolean = true,
    placeholder: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    val editorColors = NoteEditText.Colors(
        text = colors.onSurface.toArgb(), secondary = colors.onSurfaceVariant.toArgb(),
        heading = Brand.navy.toArgb().takeIf { !androidx.compose.foundation.isSystemInDarkTheme() } ?: colors.onSurface.toArgb(),
        accent = Brand.sky.toArgb(), tag = Brand.sky.toArgb(),
    )
    var isEmpty by remember { mutableStateOf(text.isEmpty()) }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    Column(modifier) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    NoteEditText(context, editorColors) { markdown ->
                        isEmpty = markdown.isEmpty()
                        onTextChange(markdown)
                    }.apply {
                        load(text)
                        controller.view = this
                        setOnFocusChangeListener { _, focused -> controller.isEditing = focused }
                        // Ein Compose-Feld (Titel) hält sonst den Fokus fest, und der Tipp hier bliebe wirkungslos.
                        setOnTouchListener { v, event ->
                            if (event.actionMasked == android.view.MotionEvent.ACTION_DOWN && !v.hasFocus()) focusManager.clearFocus(force = true)
                            false
                        }
                    }
                },
                update = { view ->
                    view.isEnabled = isEditable
                    // Text von außen (Diktat, Zusammenfassung eingefügt): neu laden.
                    if (view.isExternal(text)) {
                        view.load(text)
                        isEmpty = text.isEmpty()
                    }
                },
            )
            if (isEmpty && placeholder != null) {
                Text(placeholder, color = colors.onSurfaceVariant.copy(alpha = 0.6f), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 4.dp, top = 8.dp))
            }
        }
        if (controller.isEditing && isEditable) FormatBar(controller)
    }
    LaunchedEffect(Unit) { isEmpty = text.isEmpty() }
}

/** iOS: Formatleiste über der Tastatur. */
@Composable
private fun FormatBar(controller: NoteEditorController) {
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
            @Composable fun button(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, command: NoteEditorCommand) =
                IconButton(onClick = { controller.perform(command) }) { Icon(icon, contentDescription = label, tint = Brand.navy) }
            button(Icons.Filled.Title, "Heading", NoteEditorCommand.SetKind(Kind.Heading(2)))
            button(Icons.Filled.FormatBold, "Bold", NoteEditorCommand.ToggleInline("**"))
            button(Icons.Filled.FormatItalic, "Italic", NoteEditorCommand.ToggleInline("*"))
            button(Icons.AutoMirrored.Filled.FormatListBulleted, "Bulleted List", NoteEditorCommand.SetKind(Kind.Bullet))
            button(Icons.Filled.FormatListNumbered, "Numbered List", NoteEditorCommand.SetKind(Kind.Numbered))
            button(Icons.Filled.CheckCircleOutline, "Checklist", NoteEditorCommand.SetKind(Kind.Checklist(false)))
            button(Icons.Filled.FormatQuote, "Quote", NoteEditorCommand.SetKind(Kind.Quote))
            button(Icons.AutoMirrored.Filled.FormatIndentDecrease, "Outdent", NoteEditorCommand.Shift(false))
            button(Icons.AutoMirrored.Filled.FormatIndentIncrease, "Indent", NoteEditorCommand.Shift(true))
            IconButton(onClick = { controller.blur() }) { Icon(Icons.Filled.KeyboardHide, contentDescription = "Done", tint = Brand.navy) }
        }
    }
}

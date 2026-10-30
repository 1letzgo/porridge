package de.letzgo.porridge.ui.notes

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.text.Editable
import android.text.InputFilter
import android.text.Spanned
import android.text.TextWatcher
import android.text.style.ForegroundColorSpan
import android.text.style.ImageSpan
import android.text.style.LeadingMarginSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.TabStopSpan
import android.util.TypedValue
import android.view.MotionEvent
import androidx.appcompat.widget.AppCompatEditText
import de.letzgo.porridge.logic.editor.NoteBlock.Kind
import de.letzgo.porridge.logic.editor.NoteEditorEngine
import de.letzgo.porridge.logic.editor.NoteMarkdown
import de.letzgo.porridge.model.NoteText

/**
 * iOS: `NoteTextView` (Views/Notes/NoteTextView.swift) — die Notiz als ein natives Textfeld. Die Regeln (Return und
 * Backspace in Listen, Kürzel, Tab, Nummern, Checkboxen) liegen in [NoteEditorEngine]; dieses Feld fängt nur ab, was
 * die Engine selbst ausführt, und lässt alles andere die Tastatur tippen.
 */
@SuppressLint("ViewConstructor")
class NoteEditText(context: Context, private val colors: Colors, private val onMarkdown: (String) -> Unit) :
    // Der Plattform-Stil des Felds: das App-Theme ist kein AppCompat-Theme, ohne ihn wäre das Feld per Tipp nicht fokussierbar.
    AppCompatEditText(context, null, android.R.attr.editTextStyle) {
    data class Colors(val text: Int, val secondary: Int, val heading: Int, val accent: Int, val tag: Int)

    private val buffer = EditableBuffer(editableText)
    val engine = NoteEditorEngine(buffer) { markdown ->
        lastWritten = markdown
        written.addLast(markdown)
        if (written.size > 64) written.removeFirst()
        onMarkdown(markdown)
    }
    /** Das Markdown, das dieses Feld zuletzt geschrieben hat; anderes kam von außen (Diktat). */
    var lastWritten = ""
        private set
    /** Alles, was dieses Feld zuletzt geschrieben hat: verspätete Rückmeldungen davon sind kein Text von außen. */
    private val written = ArrayDeque<String>()

    /** Ob [markdown] von außen kommt (Diktat, eingefügte Zusammenfassung) und das Feld neu laden muss. */
    fun isExternal(markdown: String) = markdown != lastWritten && markdown !in written
    private var rendering = false
    private var pendingInsert: IntRange? = null
    private val density = resources.displayMetrics.density
    private fun dp(v: Float) = (v * density).toInt()

    init {
        background = null
        // Keine graue Fokus-Fläche über dem ganzen Text.
        defaultFocusHighlightEnabled = false
        setPadding(dp(4f), dp(8f), dp(4f), dp(96f))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        setTextColor(colors.text)
        setLineSpacing(0f, 1.15f)
        gravity = android.view.Gravity.TOP or android.view.Gravity.START
        inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        isSingleLine = false
        filters = arrayOf(InputFilter { source, start, end, _, dstart, dend ->
            val replacement = source.subSequence(start, end).toString()
            if (rendering || engine.isAdjusting || !engine.intercepts(dstart, dend, replacement)) return@InputFilter null
            // Die Engine führt die Änderung selbst aus — nach diesem Filter, nicht mitten darin.
            post {
                if (engine.shouldChange(dstart, dend, replacement)) {
                    editableText.replace(dstart, dend, replacement)
                }
                render()
            }
            ""
        })
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                if (!rendering && !engine.isAdjusting) pendingInsert = start until start + count
            }
            override fun afterTextChanged(s: Editable?) {
                if (rendering || engine.isAdjusting) return
                val inserted = pendingInsert ?: return
                pendingInsert = null
                // Was die Tastatur getippt hat, bekommt den Tippstil (iOS: typingAttributes).
                if (!inserted.isEmpty()) buffer.setStyles(inserted.first, List(inserted.count()) { buffer.typingStyle })
                engine.didChange()
                render()
            }
        })
    }

    fun load(markdown: String) {
        rendering = true
        engine.load(markdown)
        lastWritten = markdown
        written.clear()
        rendering = false
        render()
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        if (ready && !rendering) engine.selectionChanged()
    }

    // onSelectionChanged läuft schon im Konstruktor der Basisklasse, bevor die Felder hier stehen.
    private var ready = false
    init { ready = true }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP && layout != null) {
            val offset = getOffsetForPosition(event.x, event.y)
            val near = (offset - 1..offset).firstOrNull { it in 0 until text!!.length && buffer.style(it).checkbox }
            if (near != null) {
                val line = layout.getLineForOffset(near)
                val x = layout.getPrimaryHorizontal(near) + totalPaddingLeft
                if (event.x <= x + dp(28f) && layout.getLineForVertical((event.y - totalPaddingTop + scrollY).toInt()) == line) {
                    engine.toggleCheckbox(near)
                    render()
                    return true
                }
            }
        }
        return super.onTouchEvent(event)
    }

    /** Setzt die Darstellung aus den Zeichenattributen neu (iOS: Absatzstil, Schriften, Marker, Tag-Farbe). */
    fun render() {
        val e = editableText
        rendering = true
        try {
            for (cls in listOf(RelativeSizeSpan::class.java, StyleSpan::class.java, ForegroundColorSpan::class.java, LeadingMarginSpan::class.java, TabStopSpan::class.java, ImageSpan::class.java)) {
                e.getSpans(0, e.length, cls).forEach { e.removeSpan(it) }
            }
            val step = dp(22f)
            val markerWidth = dp(26f)
            var location = 0
            while (location < e.length) {
                val range = NoteMarkdown.paragraphRange(e, location)
                val end = range.last + 1
                val (kind, indent) = NoteMarkdown.kind(buffer.style(range.first))
                val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
                when (kind) {
                    is Kind.Heading -> {
                        e.setSpan(RelativeSizeSpan(when (kind.level) { 1 -> 1.55f; 2 -> 1.3f; else -> 1.12f }), range.first, end, flags)
                        e.setSpan(StyleSpan(Typeface.BOLD), range.first, end, flags)
                        e.setSpan(ForegroundColorSpan(colors.heading), range.first, end, flags)
                    }
                    Kind.Quote -> {
                        e.setSpan(QuoteMargin(colors.accent, dp(3f), dp(14f)), range.first, end, Spanned.SPAN_PARAGRAPH)
                        e.setSpan(ForegroundColorSpan(colors.secondary), range.first, end, flags)
                    }
                    Kind.Bullet, Kind.Numbered, is Kind.Checklist -> {
                        val lead = indent * step
                        e.setSpan(LeadingMarginSpan.Standard(lead, lead + markerWidth), range.first, end, Spanned.SPAN_PARAGRAPH)
                        e.setSpan(TabStopSpan.Standard(lead + markerWidth), range.first, end, Spanned.SPAN_PARAGRAPH)
                        if (kind is Kind.Checklist && kind.checked) {
                            e.setSpan(ForegroundColorSpan(colors.secondary), range.first, end, flags)
                        }
                    }
                    Kind.Paragraph -> Unit
                }
                location = end
            }
            for (i in 0 until e.length) {
                val style = buffer.style(i)
                when {
                    style.checkbox -> e.setSpan(ImageSpan(Checkbox(style.checked, colors, dp(18f)), ImageSpan.ALIGN_BASELINE), i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    style.marker -> e.setSpan(ForegroundColorSpan(colors.secondary), i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                if (style.bold && style.block?.startsWith("h") != true) e.setSpan(StyleSpan(Typeface.BOLD), i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (style.italic) e.setSpan(StyleSpan(Typeface.ITALIC), i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            // `#tags` in der Akzentfarbe (iOS: colorTags).
            var lineStart = 0
            for (line in e.toString().split("\n")) {
                for (r in NoteText.tagRanges(line)) e.setSpan(ForegroundColorSpan(colors.tag), lineStart + r.first, lineStart + r.last + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                lineStart += line.length + 1
            }
        } finally {
            rendering = false
        }
    }

    /** Der Strich links an einem Zitat. */
    private class QuoteMargin(private val color: Int, private val width: Int, private val gap: Int) : LeadingMarginSpan {
        override fun getLeadingMargin(first: Boolean) = width + gap
        override fun drawLeadingMargin(c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int, text: CharSequence?, start: Int, end: Int, first: Boolean, layout: android.text.Layout?) {
            val old = p.color
            val style = p.style
            p.color = color
            p.style = Paint.Style.FILL
            c.drawRect(x.toFloat(), top.toFloat(), (x + dir * width).toFloat(), bottom.toFloat(), p)
            p.color = old
            p.style = style
        }
    }

    /** iOS: `NoteMarkdown.checkboxImage` — Kreis, abgehakt gefüllt mit Häkchen. */
    private class Checkbox(private val checked: Boolean, private val colors: Colors, private val size: Int) : Drawable() {
        init { setBounds(0, 0, size + size / 2, size) }
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        override fun draw(canvas: Canvas) {
            val r = size / 2f
            val cx = r
            val cy = r
            if (checked) {
                paint.style = Paint.Style.FILL
                paint.color = colors.accent
                canvas.drawCircle(cx, cy, r - 1, paint)
                paint.color = android.graphics.Color.WHITE
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = size / 9f
                paint.strokeCap = Paint.Cap.ROUND
                val path = android.graphics.Path().apply {
                    moveTo(cx - r * 0.45f, cy)
                    lineTo(cx - r * 0.1f, cy + r * 0.35f)
                    lineTo(cx + r * 0.5f, cy - r * 0.35f)
                }
                canvas.drawPath(path, paint)
            } else {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = size / 11f
                paint.color = colors.secondary
                canvas.drawCircle(cx, cy, r - paint.strokeWidth, paint)
            }
        }
        override fun setAlpha(alpha: Int) {}
        override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {}
        @Deprecated("Deprecated in Java")
        override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
    }
}

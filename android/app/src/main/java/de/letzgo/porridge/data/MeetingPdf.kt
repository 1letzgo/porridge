package de.letzgo.porridge.data

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LeadingMarginSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import de.letzgo.porridge.logic.MeetingExport
import java.io.File

/** iOS: `MeetingExport.pdfData` — A4-Seiten mit dem Titel auf der ersten und Seitenzahlen auf allen. */
object MeetingPdf {
    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 56
    private val navy = Color.rgb(0x1F, 0x36, 0x67)
    private val body = Color.rgb(33, 33, 38)
    private val muted = Color.rgb(115, 115, 122)

    fun write(export: MeetingExport, file: File) {
        val content = content(export)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 11f; color = body }
        val width = PAGE_WIDTH - 2 * MARGIN
        val layout = StaticLayout.Builder.obtain(content, 0, content.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(2f, 1f).setIncludePad(false).build()
        val height = PAGE_HEIGHT - 2 * MARGIN
        val document = PdfDocument()
        var line = 0
        var number = 1
        while (line < layout.lineCount) {
            val top = layout.getLineTop(line)
            // So viele ganze Zeilen, wie auf die Seite passen.
            var end = line
            while (end < layout.lineCount && layout.getLineBottom(end) - top <= height) end++
            if (end == line) end = line + 1
            val page = document.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, number).create())
            draw(page.canvas, layout, top, layout.getLineBottom(end - 1), number)
            document.finishPage(page)
            line = end
            number++
        }
        file.outputStream().use { document.writeTo(it) }
        document.close()
    }

    private fun draw(canvas: Canvas, layout: StaticLayout, top: Int, bottom: Int, number: Int) {
        canvas.save()
        canvas.translate(MARGIN.toFloat(), (MARGIN - top).toFloat())
        canvas.clipRect(0, top, PAGE_WIDTH - 2 * MARGIN, bottom)
        layout.draw(canvas)
        canvas.restore()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 9f; color = muted; textAlign = Paint.Align.CENTER }
        canvas.drawText(number.toString(), PAGE_WIDTH / 2f, PAGE_HEIGHT - 30f, paint)
    }

    private fun content(export: MeetingExport): SpannableStringBuilder {
        val out = SpannableStringBuilder()
        out.styled(export.title, size = 22, color = navy, bold = true)
        out.gap(4)
        out.styled(export.date, size = 11, color = muted)
        out.gap(14)
        export.summary?.takeIf { it.isNotEmpty() }?.let { summary ->
            out.styled("Summary", size = 15, color = navy, bold = true)
            out.gap(8)
            summary(out, summary)
            out.gap(10)
        }
        if (export.transcript.isNotEmpty()) {
            out.styled("Transcript", size = 15, color = navy, bold = true)
            out.gap(8)
            for (line in export.transcript) {
                val start = out.length
                out.styled(line.time + "  ", size = 9, color = muted, mono = true, breakAfter = false)
                line.speaker?.let { out.styled("$it: ", size = 11, color = navy, bold = true, breakAfter = false) }
                out.styled(line.text, size = 11, color = body)
                check(start <= out.length)
                out.gap(5)
            }
        }
        return out
    }

    private fun summary(out: SpannableStringBuilder, markdown: String) {
        for (raw in markdown.split("\n")) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            if (line.startsWith("#")) {
                out.gap(4)
                out.styled(line.trimStart('#').trim().replace("**", ""), size = 13, color = navy, bold = true)
                out.gap(4)
                continue
            }
            val item = listOf("- [ ] " to "☐", "- [x] " to "☑", "- [X] " to "☑", "- " to "•", "* " to "•", "• " to "•").firstOrNull { line.startsWith(it.first) }
            val start = out.length
            if (item != null) out.styled(item.second + "  ", size = 11, color = body, breakAfter = false)
            inlineBold(out, if (item != null) line.removePrefix(item.first) else line)
            if (item != null) out.setSpan(LeadingMarginSpan.Standard(0, 16), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            out.append("\n")
            out.gap(3)
        }
    }

    /** `**fett**` wird fett, der Rest ist Fließtext. */
    private fun inlineBold(out: SpannableStringBuilder, text: String) {
        text.split("**").forEachIndexed { index, piece ->
            if (piece.isNotEmpty()) out.styled(piece, size = 11, color = body, bold = index % 2 == 1, breakAfter = false)
        }
    }

    private fun SpannableStringBuilder.styled(text: String, size: Int, color: Int, bold: Boolean = false, mono: Boolean = false, breakAfter: Boolean = true) {
        val start = length
        append(text)
        setSpan(AbsoluteSizeSpan(size), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(ForegroundColorSpan(color), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (bold) setSpan(StyleSpan(Typeface.BOLD), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (mono) setSpan(TypefaceSpan("monospace"), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (breakAfter) append("\n")
    }

    /** Ein Abstand aus einer kleinen Leerzeile. */
    private fun SpannableStringBuilder.gap(size: Int) {
        val start = length
        append("\n")
        setSpan(AbsoluteSizeSpan(size), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
}

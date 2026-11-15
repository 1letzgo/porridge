package de.letzgo.porridge.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import de.letzgo.porridge.model.Attachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * iOS: `AttachmentText` (Services/AttachmentText.swift) — liest den Text aus Anhängen, auf dem Gerät: gedruckten Text in
 * Bildern (ML Kit, das mitgelieferte Modell für lateinische Schrift), PDFs (jede Seite wird als Bild gelesen; Android hat
 * keinen Zugriff auf die Textebene) und reine Textdateien. Der Text wird `pageText` der Notiz.
 */
object AttachmentText {
    const val LIMIT = 200_000
    /** So viele PDF-Seiten werden höchstens gelesen. */
    const val PDF_PAGES = 30
    private val textExtensions = setOf("txt", "md", "markdown", "csv", "json", "xml", "html", "htm", "log", "yaml", "yml")

    /** Der Text aller Dateien in ihrer Reihenfolge; die Seiten eines PDFs sind markiert („Page 3“). */
    suspend fun read(files: List<Pair<File, Attachment>>): String = withContext(Dispatchers.Default) {
        val parts = mutableListOf<String>()
        var length = 0
        for ((file, attachment) in files) {
            if (length >= LIMIT) break
            val text = runCatching {
                when (attachment.kind) {
                    Attachment.Kind.IMAGE -> image(file)
                    Attachment.Kind.PDF -> pdf(file)
                    Attachment.Kind.FILE -> plain(file)
                }
            }.getOrDefault("").trim()
            if (text.isEmpty()) continue
            // Mehrere Dateien: Jede beginnt mit ihrem Namen.
            parts += if (files.size > 1) "${attachment.name}\n$text" else text
            length += text.length
        }
        parts.joinToString("\n\n").take(LIMIT)
    }

    fun plain(file: File): String {
        // Word, OpenDocument und Rich Text haben ihren eigenen Leser.
        val document = DocumentText.read(file)
        if (document.isNotEmpty()) return document
        return if (file.extension.lowercase() in textExtensions && file.length() < 2_000_000) file.readText() else ""
    }

    private fun recognize(bitmap: Bitmap): String {
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        return try {
            Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0))).text
        } finally {
            recognizer.close()
        }
    }

    private fun image(file: File): String {
        // Verkleinert dekodiert: Ein 50-MP-Foto passte sonst nicht in den Speicher.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3000) sample *= 2
        val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return ""
        return try { recognize(bitmap) } finally { bitmap.recycle() }
    }

    private fun pdf(file: File): String {
        val pages = mutableListOf<String>()
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                var length = 0
                for (index in 0 until minOf(renderer.pageCount, PDF_PAGES)) {
                    if (length >= LIMIT) break
                    val text = renderer.openPage(index).use { page ->
                        val scale = minOf(2.5f, 2200f / maxOf(page.width, page.height))
                        val bitmap = Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                        try {
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            recognize(bitmap).trim()
                        } finally {
                            bitmap.recycle()
                        }
                    }
                    if (text.isEmpty()) continue
                    pages += if (renderer.pageCount > 1) "Page ${index + 1}\n$text" else text
                    length += text.length
                }
            }
        }
        return pages.joinToString("\n\n")
    }
}

package de.letzgo.porridge.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import de.letzgo.porridge.model.Attachment
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * iOS: `ShareImport` + die Share-Extension (`PorridgeShare`, `Shared/ShareInbox.swift`). Auf Android kommt Geteiltes
 * direkt per `ACTION_SEND`/`ACTION_SEND_MULTIPLE` in die App: ein Link, Text, Bilder, PDFs, Dateien oder Audio. Daraus
 * werden Einträge im Eingang; jedes Bild, PDF oder Dokument wird ein Bild oder eine Datei für sich (`Note.isImage`, `Note.isFile`).
 */
object ShareImport {
    /** Was ein Intent mitbringt, bevor es gespeichert ist. */
    data class Shared(val text: String?, val title: String?, val uris: List<Uri>) {
        val isEmpty: Boolean get() = text.isNullOrBlank() && uris.isEmpty()
    }

    fun read(intent: Intent?): Shared? {
        if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE)) return null
        @Suppress("DEPRECATION")
        val uris = if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        val shared = Shared(intent.getStringExtra(Intent.EXTRA_TEXT), intent.getStringExtra(Intent.EXTRA_SUBJECT), uris)
        return shared.takeUnless { it.isEmpty }
    }

    /** iOS: `ShareViewController.onlyLink` — die Adresse, wenn der Text ein einzelner Link ist (mit höchstens ein paar Worten davor). */
    fun onlyLink(text: String): String? {
        val address = LinkImport.webAddress(text) ?: return null
        return address.takeIf { text.trim().length <= address.length + 80 }
    }

    /** Speichert das Geteilte und gibt die Notiz zurück, die sich öffnen soll. */
    suspend fun save(context: Context, shared: Shared, project: String? = null): Note? {
        val db = PorridgeDatabase.shared
        var first: Note? = null
        val attachments = mutableListOf<Attachment>()
        for (uri in shared.uris) {
            val name = displayName(context, uri)
            val mime = context.contentResolver.getType(uri).orEmpty()
            val extension = name.substringAfterLast('.', "").lowercase().ifEmpty { MimeTypeMap.getSingleton().getExtensionFromMimeType(mime).orEmpty() }
            val stored = runCatching { withContext(Dispatchers.IO) { AudioStore.importFile(context, uri, extension.ifEmpty { "bin" }) } }.getOrNull() ?: continue
            if (mime.startsWith("audio/") || mime.startsWith("video/")) {
                val info = withContext(Dispatchers.IO) { AudioStore.audioInfo(stored) }
                val note = Note(
                    title = name.substringBeforeLast('.'), titleIsCustom = true, statusRaw = ProcessingStatus.RECORDED.raw, audioFileName = stored,
                    inputName = "Import", duration = info?.first ?: 0.0, channelCount = info?.second ?: 1,
                    projectIDs = listOfNotNull(project), sourceRaw = NoteSource.SHARE.raw,
                )
                db.notes().upsert(note)
                ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
                first = first ?: note
            } else {
                attachments += Attachment(fileName = stored, name = name, kindRaw = kind(mime, extension).raw, bytes = AudioStore.file(stored).length())
            }
        }
        val text = shared.text.orEmpty().trim()
        val link = if (attachments.isEmpty()) onlyLink(text) else null
        when {
            // Jede Datei für sich; mitgeteilter Text beschreibt die erste, ein mitgeteilter Titel benennt eine einzelne.
            attachments.isNotEmpty() -> attachments.forEachIndexed { index, attachment ->
                val note = Note(
                    title = shared.title?.takeIf { it.isNotBlank() && attachments.size == 1 } ?: attachment.name.substringBeforeLast('.'),
                    text = if (index == 0) text else "", statusRaw = ProcessingStatus.RECORDED.raw, projectIDs = listOfNotNull(project), sourceRaw = NoteSource.SHARE.raw,
                ).withAttachments(listOf(attachment))
                db.notes().upsert(note)
                ProcessingService.enqueue(ProcessingService.Job.Attachment(note.id))
                first = first ?: note
            }
            link != null -> first = LinkImport.add(link, project = project, title = shared.title)
            text.isNotEmpty() -> {
                val note = Note(title = shared.title.orEmpty().trim(), text = text, projectIDs = listOfNotNull(project), sourceRaw = NoteSource.SHARE.raw)
                db.notes().upsert(note)
                first = note
            }
        }
        return first
    }

    fun kind(mime: String, extension: String): Attachment.Kind = when {
        mime == "application/pdf" || extension == "pdf" -> Attachment.Kind.PDF
        mime.startsWith("image/") || extension in setOf("png", "jpg", "jpeg", "heic", "webp", "gif") -> Attachment.Kind.IMAGE
        else -> Attachment.Kind.FILE
    }

    private fun displayName(context: Context, uri: Uri): String =
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (c.moveToFirst() && i >= 0) c.getString(i) else null
            }
        }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "File"
}

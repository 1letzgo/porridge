package de.letzgo.porridge.data

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.PorridgeDatabase
import java.net.URI

/**
 * iOS: `LinkImport` + `Shared/LinkInbox.swift` (Share-Extension). Auf Android kommt ein geteilter Link direkt per
 * `ACTION_SEND` in die App und wird hier gespeichert.
 */
object LinkImport {
    private val urlRegex = Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE)

    /** Eine Webadresse aus Text („Schau mal: https://…“) oder null. */
    fun webAddress(text: String): String? {
        val trimmed = text.trim()
        val candidate = urlRegex.find(trimmed)?.value ?: if (!trimmed.contains(' ') && trimmed.contains('.')) "https://$trimmed" else return null
        val clean = candidate.trimEnd('.', ',', ')', ';', '!', '?')
        val host = runCatching { URI(clean).host }.getOrNull()
        return clean.takeIf { !host.isNullOrBlank() && host.contains('.') }
    }

    /** Speichert den Link als Notiz und lädt die Seite (mit Zusammenfassung). Ein schon gespeicherter Link wird nicht doppelt angelegt. */
    suspend fun add(address: String, folderID: String? = null): Note {
        val db = PorridgeDatabase.shared
        db.notes().all().firstOrNull { it.url == address && !it.isDeleted }?.let { return it }
        val note = Note(url = address, title = address, statusRaw = ProcessingStatus.RECORDED.raw, folderID = folderID)
        db.notes().upsert(note)
        ProcessingService.enqueue(ProcessingService.Job.Link(note.id, summarize = true))
        return note
    }
}

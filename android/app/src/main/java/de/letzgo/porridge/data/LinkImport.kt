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

    /** iOS: `LinkImport.normalized` — eine Adresse ohne Fragment und Schrägstrich am Ende, um denselben Link wiederzufinden. */
    fun normalized(address: String): String = runCatching {
        val uri = URI(address.trim())
        URI(uri.scheme?.lowercase(), uri.userInfo, uri.host?.lowercase(), uri.port, uri.path, uri.query, null).toString().trimEnd('/')
    }.getOrDefault(address.trim().trimEnd('/'))

    /**
     * Speichert den Link als Notiz im Eingang und lädt die Seite (mit Zusammenfassung). Ein schon gespeicherter Link wird
     * nicht doppelt angelegt: Er kommt aus dem Papierkorb zurück und rückt nach oben.
     */
    suspend fun add(address: String, project: String? = null, title: String? = null): Note {
        val db = PorridgeDatabase.shared
        val key = normalized(address)
        db.notes().all().firstOrNull { it.url != null && normalized(it.url) == key }?.let { existing ->
            val moved = existing.copy(deletedAt = null, updatedAt = System.currentTimeMillis())
            db.notes().upsert(moved)
            return moved
        }
        val note = Note(
            url = address, title = title?.takeIf { it.isNotBlank() && !it.startsWith("http") } ?: address,
            statusRaw = ProcessingStatus.RECORDED.raw, projectIDs = listOfNotNull(project), sourceRaw = de.letzgo.porridge.model.NoteSource.LINK.raw,
        )
        db.notes().upsert(note)
        // Hier hereingekommen: Dieses Gerät fasst ihn zusammen, sobald die Seite geladen ist (`AutoSummary`).
        de.letzgo.porridge.logic.AutoSummary.origins.mark(note.id)
        ProcessingService.enqueue(ProcessingService.Job.Link(note.id, summarize = true))
        return note
    }
}

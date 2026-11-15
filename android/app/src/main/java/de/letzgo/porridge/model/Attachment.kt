package de.letzgo.porridge.model

import kotlinx.serialization.Serializable
import java.util.UUID

/** iOS: `NoteSource` (Models/Attachment.swift) — der Kanal, über den eine Notiz in die App kam. */
enum class NoteSource(val raw: String, val label: String) {
    /** Aus der Zeit vor den Kanälen. */
    UNKNOWN("", "Note"),
    NOTE("note", "Note"),
    MEETING("meeting", "Meeting"),
    LINK("link", "Link"),
    /** Aus einer anderen App geteilt. */
    SHARE("share", "Shared"),
    PLAUD("plaud", "Plaud"),
    /** Eine Audiodatei von außen. */
    AUDIO_IMPORT("import", "Import");

    companion object {
        fun of(raw: String) = entries.firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

/**
 * iOS: `Attachment` (Models/Attachment.swift) — eine Datei, die zu einer Notiz gehört. Sie liegt im selben Speicher wie
 * die Aufnahmen (`AudioStore`) und reist genauso zu den anderen Geräten. Feldnamen wie im iOS-JSON.
 */
@Serializable
data class Attachment(
    val id: String = UUID.randomUUID().toString().uppercase(),
    /** Name im Speicher. */
    val fileName: String,
    /** Wie die Datei dort hieß, wo sie herkam. */
    val name: String,
    val kindRaw: String,
    val bytes: Long = 0,
) {
    val kind: Kind get() = Kind.entries.firstOrNull { it.raw == kindRaw } ?: Kind.FILE

    enum class Kind(val raw: String) { IMAGE("image"), PDF("pdf"), FILE("file") }
}

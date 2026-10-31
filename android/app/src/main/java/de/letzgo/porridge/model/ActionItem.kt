package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * iOS: `ActionItem` (Models/ActionItem.swift) — eine Aufgabe (oder Entscheidung) mit eigenem Titel, Zuständigem,
 * Erledigt-Stand und eigenem Text. Die meisten stammen aus der Zusammenfassung einer Notiz (`noteID`); sie lassen
 * sich umbenennen und beschreiben und bleiben, wenn ihre Zeile oder Notiz geht. Abhaken setzt auch die Zeile in
 * der Zusammenfassung.
 */
@Serializable
@Entity(tableName = "action_items", indices = [Index("noteID")])
data class ActionItem(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    /** `Note.id` der Notiz, aus der der Eintrag stammt. */
    val noteID: String? = null,
    val kindRaw: String = Kind.TASK.raw,
    val text: String = "",
    /** Wer zuständig ist, wenn die Zusammenfassung es sagt („Aufgabe – Anna“). */
    val owner: String? = null,
    val isDone: Boolean = false,
    val doneAt: Long? = null,
    val createdAt: Long = System.currentTimeMillis(),
    /** Position in der Zusammenfassung, damit die Reihenfolge überall gleich bleibt. */
    val order: Int = 0,
    /**
     * Herkunft: "summary" (folgt der Zusammenfassung), "manual" (von Hand angelegt) oder "kept" (kam aus einer
     * Zusammenfassung, wurde bearbeitet und lebt eigenständig weiter, weil ihre Zeile weg ist).
     */
    val source: String = "summary",
    /** Eigener Text der Aufgabe (Markdown wie der Text einer Notiz): Details, Links, Teilschritte. */
    val details: String = "",
    /** Die Zusammenfassungs-Zeile, aus der der Eintrag entstand (`ActionItemsLogic.key`); bleibt beim Umbenennen. */
    val summaryKey: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    /** Ob eine Aufgabe aus der Zusammenfassung angesehen wurde ([Review]). Einträge von vor der Prüfung gelten als übernommen. */
    val reviewRaw: String = Review.ACCEPTED.raw,
    /** Eigene Projekte (`NoteFolder.id`); die der Notiz, aus der sie stammt, gelten mit. */
    val projectIDs: List<String> = emptyList(),
) {
    enum class Kind(val raw: String) {
        TASK("task"),
        DECISION("decision");

        companion object {
            fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: TASK
        }
    }

    /** Eine Aufgabe aus der Zusammenfassung ist erst ein Vorschlag: sie wartet unter „New“, bis sie übernommen oder verworfen wird. */
    enum class Review(val raw: String) {
        PENDING("pending"),
        ACCEPTED("accepted"),
        /** Verworfen: überall ausgeblendet, aber behalten, damit ihre Zeile sie nicht wiederbringt. */
        DISMISSED("dismissed");

        companion object {
            fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: ACCEPTED
        }
    }

    val kind: Kind get() = Kind.of(kindRaw)
    val review: Review get() = Review.of(reviewRaw)
    val isFromSummary: Boolean get() = source == "summary"

    /** Neu aus einer Zusammenfassung und noch nicht angesehen (eine abgehakte braucht keine Prüfung). */
    val needsReview: Boolean get() = review == Review.PENDING && !isDone

    /** Text mit Zuständigem, wie er in der Zusammenfassung steht. */
    val line: String get() = owner?.let { "$text – $it" } ?: text
}

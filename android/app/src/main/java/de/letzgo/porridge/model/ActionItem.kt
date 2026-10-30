package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * iOS: `ActionItem` (Models/ActionItem.swift) — eine Aufgabe oder Entscheidung aus der Zusammenfassung einer
 * Notiz, abhakbar und über alle Meetings abfragbar. Abhaken setzt auch die Zeile in der Zusammenfassung.
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
    /** Herkunft: "summary" (folgt der Zusammenfassung) oder "manual". */
    val source: String = "summary",
) {
    enum class Kind(val raw: String) {
        TASK("task"),
        DECISION("decision");

        companion object {
            fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: TASK
        }
    }

    val kind: Kind get() = Kind.of(kindRaw)
    val isFromSummary: Boolean get() = source == "summary"

    /** Text mit Zuständigem, wie er in der Zusammenfassung steht. */
    val line: String get() = owner?.let { "$text – $it" } ?: text
}

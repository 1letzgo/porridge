package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * iOS: `ChatThread` (Models/Chat.swift) — ein Gespräch mit den Notizen. Mehrere stehen nebeneinander; ein Chat geht
 * über alles oder über einen Bucket. Chats bleiben auf dem Gerät, auf dem sie geführt wurden: Sie werden nicht abgeglichen.
 */
@Entity(tableName = "chat_threads")
data class ChatThread(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    /** Die erste Frage, gekürzt. */
    val title: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    /** Der Bucket, über den der Chat geht; null ist alles. */
    val projectID: String? = null,
)

/** iOS: `ChatEntry` — eine Nachricht eines Chats: eine Frage, oder die Antwort mit den Notizen, aus denen sie stammt. */
@Entity(tableName = "chat_entries", indices = [Index("threadID")])
data class ChatEntry(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    val threadID: String,
    /** "user" oder "assistant". */
    val roleRaw: String,
    val text: String,
    val createdAt: Long = System.currentTimeMillis(),
    /** Die Antwort ist eine Fehlermeldung (kein Modell, keine Verbindung). */
    val isError: Boolean = false,
    /** Die Notizen hinter einer Antwort, als JSON (`List<ChatSource>`). */
    val sourcesData: String? = null,
) {
    val isUser: Boolean get() = roleRaw == "user"
}

/** iOS: `ChatSource` — eine Notiz, aus der eine Antwort stammt. */
@Serializable
data class ChatSource(val noteID: String, val title: String, val date: Long)

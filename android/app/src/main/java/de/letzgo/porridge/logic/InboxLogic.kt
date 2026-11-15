package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import java.text.Normalizer

/**
 * iOS: `Inbox` (Services/Inbox.swift) — der Eingang: alles, was in keinem Bucket liegt, Neuestes zuerst. Eine Notiz
 * verlässt ihn nur, indem sie in einen Bucket (ein Projekt) abgelegt wird, und ist zurück, wenn sie ihren letzten
 * verlässt. Buckets werden nur vorgeschlagen; der Nutzer nimmt einen Vorschlag an oder verwirft ihn.
 */
object InboxLogic {
    /** Was im Eingang wartet, Neuestes zuerst. */
    fun notes(all: List<Note>): List<Note> = all.filter { it.isInInbox }.sortedByDescending { it.createdAt }

    /** In einen Bucket abgelegt: aus dem Eingang, die Vorschläge sind erledigt. */
    fun filed(note: Note, project: String, now: Long = System.currentTimeMillis()): Note = note.copy(
        projectIDs = if (project in note.projectIDs) note.projectIDs else note.projectIDs + project,
        filedAt = note.filedAt ?: now, suggestedProjectIDs = emptyList(),
    )

    /** Die Buckets, aus denen ein Modell für diese Notiz wählen darf: die aktiven, solange sie in keinem liegt. */
    fun candidates(note: Note, folders: List<NoteFolder>): List<NoteFolder> =
        if (note.projectIDs.isNotEmpty()) emptyList()
        else folders.filter { it.archivedAt == null && it.name.isNotBlank() }.sortedBy { it.name.lowercase() }

    /** Die Zeile, die einem Zusammenfassungs-Prompt angehängt wird, damit das Modell einen Bucket nennt. Leer ohne Buckets. */
    fun promptLine(projects: List<NoteFolder>): String {
        val names = projects.map { it.name.replace("|", "/") }.filter { it.isNotEmpty() }
        if (names.isEmpty()) return ""
        return "\nPROJECT: <the one bucket from this list that this clearly belongs to, written exactly as listed, or \"none\" when none clearly fits: ${names.joinToString(" | ")}>"
    }

    /** Nimmt die Zeile „PROJECT: Name“ von der Antwort. Der Name zählt nur, wenn er einer der Buckets ist. */
    fun splitProject(text: String, projects: List<NoteFolder>): Pair<String, NoteFolder?> {
        val lines = text.split("\n").toMutableList()
        val index = lines.indexOfLast { it.trim().uppercase().startsWith("PROJECT:") }
        if (index < 0) return text to null
        val name = lines.removeAt(index).trim().drop("PROJECT:".length).trim().trim('"', '\'', '*', '<', '>', '.', '`').trim()
        val match = projects.firstOrNull { sameName(it.name, name) }
        return lines.joinToString("\n").trim() to match
    }

    /** Groß/klein und Akzente egal (iOS: `.caseInsensitive, .diacriticInsensitive`). */
    fun sameName(a: String, b: String): Boolean = fold(a) == fold(b)

    private fun fold(text: String): String =
        Normalizer.normalize(text.trim(), Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
}

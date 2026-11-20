package de.letzgo.porridge.logic

import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.ProcessingStatus

/**
 * iOS: `AutoSummary` (Services/AutoSummary.swift) — was von außen hereinkommt, bekommt von selbst eine Zusammenfassung,
 * sobald sein Inhalt da ist: ein Link, wenn seine Seite geladen ist, ein Bild oder eine Datei, wenn ihr Text gelesen ist,
 * aus einer anderen App geteilter Text, und importiertes Audio (eine Datei oder Plaud), wenn es transkribiert ist. Die
 * eigenen Notizen, To-dos und Aufnahmen werden nur auf Wunsch zusammengefasst.
 *
 * Ein Gerät macht die Arbeit: das, auf dem der Eintrag hereinkam ([Origins], nur auf diesem Gerät). Ein anderes holt nach,
 * wenn ein Eintrag [CATCH_UP_DELAY] nach seiner letzten Änderung noch keine Zusammenfassung hat. Nichts Neues wird
 * synchronisiert: Eine Zusammenfassung reist in den Feldern, in denen sie immer reiste.
 *
 * Nie zweimal, nie über den Nutzer: Nur ein Eintrag ohne Zusammenfassung und ohne `summarizedAt` wird zusammengefasst. Eine
 * gelöschte Zusammenfassung behält ihr `summarizedAt` (`SummaryLogic.removeSummary`) und kommt nicht von selbst wieder.
 * DESIGN.md „Summaries of incoming entries“.
 */
object AutoSummary {
    enum class Kind { LINK, IMAGE, FILE, SHARED_TEXT, IMPORTED_AUDIO }

    /** Weniger Text ist keine Zusammenfassung wert (ein Foto mit einem Wort darauf, eine Seite, die nicht lesbar war). */
    const val MINIMUM_CHARACTERS = 280
    /** So lange überlässt ein anderes Gerät einen Eintrag dem, auf dem er hereinkam. */
    const val CATCH_UP_DELAY = 2 * 3_600_000L
    /** Ein anderes Gerät holt nur Einträge der letzten 30 Tage nach, nicht alles je Gespeicherte. */
    const val CATCH_UP_WINDOW = 30 * 86_400_000L
    /** Eine gescheiterte Zusammenfassung wird nach so langer Zeit wieder versucht, höchstens [ATTEMPTS_PER_LAUNCH]-mal, solange die App läuft. */
    const val RETRY_DELAY = 15 * 60_000L
    const val ATTEMPTS_PER_LAUNCH = 3

    /** Einstellung „Summarize Incoming Entries“ (Standard an). */
    val enabled: Boolean get() = Prefs.bool(Keys.SUMMARIZE_INCOMING)

    /** Die Art eines hereingekommenen Eintrags; null für die eigenen Notizen, To-dos und Aufnahmen. */
    fun kind(note: Note): Kind? = when {
        note.isTodo -> null
        note.isLink -> Kind.LINK
        note.isStored -> if (note.isImage) Kind.IMAGE else Kind.FILE
        note.isRecording -> if (note.source == NoteSource.AUDIO_IMPORT || note.source == NoteSource.PLAUD) Kind.IMPORTED_AUDIO else null
        note.source == NoteSource.SHARE && note.attachmentsData == null -> Kind.SHARED_TEXT
        else -> null
    }

    /** Der Text, aus dem die Zusammenfassung entsteht. */
    fun material(note: Note, kind: Kind): String = when (kind) {
        Kind.LINK, Kind.IMAGE, Kind.FILE -> note.pageText.orEmpty()
        Kind.SHARED_TEXT -> note.text
        Kind.IMPORTED_AUDIO -> note.transcriptText(timestamps = false)
    }.trim()

    /** Ob [note] jetzt zusammengefasst werden soll. [isOrigin]: Sie kam auf diesem Gerät herein. */
    fun isDue(note: Note, isOrigin: Boolean, enabled: Boolean = this.enabled, now: Long = System.currentTimeMillis()): Boolean {
        if (!enabled || note.isDeleted || note.summary != null || note.summarizedAt != null) return false
        val kind = kind(note) ?: return false
        if (note.status != ProcessingStatus.READY || note.pendingAudioFileName != null) return false
        if (material(note, kind).length < MINIMUM_CHARACTERS) return false
        if (isOrigin) return true
        return now - note.updatedAt >= CATCH_UP_DELAY && now - note.createdAt <= CATCH_UP_WINDOW
    }

    /**
     * Wo ein Eintrag hereinkam: die Notizen, die auf diesem Gerät hereinkamen und noch auf ihre Zusammenfassung warten
     * (iOS: `origins` in `UserDefaults`, Schlüssel `autoSummaryOrigins`). Nur auf diesem Gerät, nie synchronisiert.
     */
    class Origins(private val read: () -> Set<String>, private val write: (Set<String>) -> Unit) {
        fun all(): Set<String> = read()

        fun contains(id: String) = id in read()

        /** Gerufen, wo ein Eintrag hereinkommt: Teilen, eingefügter oder hinzugefügter Link, gewählte Datei, importiertes Audio, Plaud. */
        fun mark(id: String) {
            val all = read()
            if (id !in all) write(all + id)
        }

        /** Zusammengefasst (oder weg): Die Marke wird nicht mehr gebraucht. */
        fun clear(id: String) {
            val all = read()
            if (id in all) write(all - id)
        }

        /** Marken von Notizen, die weg oder zusammengefasst sind, fallen weg, damit die Liste nicht immer wächst. */
        fun prune(keeping: List<Note>) {
            val waiting = keeping.filter { !it.isDeleted && it.summary == null && it.summarizedAt == null }.map { it.id }.toSet()
            val all = read()
            val kept = all intersect waiting
            if (kept != all) write(kept)
        }
    }

    const val ORIGINS_KEY = "autoSummaryOrigins"

    /** Die Marken dieses Geräts. */
    val origins = Origins({ Prefs.stringSet(ORIGINS_KEY) }, { Prefs.set(ORIGINS_KEY, it) })

    /** Gescheiterte Versuche, solange die App läuft: wann der nächste beginnen darf. */
    class Attempts {
        private val failures = HashMap<String, Pair<Int, Long>>()

        @Synchronized fun mayTry(id: String, now: Long = System.currentTimeMillis()): Boolean {
            val (count, last) = failures[id] ?: return true
            return count < ATTEMPTS_PER_LAUNCH && now - last >= RETRY_DELAY
        }

        @Synchronized fun failed(id: String, now: Long = System.currentTimeMillis()) {
            failures[id] = ((failures[id]?.first ?: 0) + 1) to now
        }

        @Synchronized fun succeeded(id: String) {
            failures.remove(id)
        }
    }
}

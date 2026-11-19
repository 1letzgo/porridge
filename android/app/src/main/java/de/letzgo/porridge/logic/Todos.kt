package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.TodoState
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.util.Calendar

/**
 * iOS: `Todos` (Services/Todos.swift) — die Regeln der To-dos, ohne Oberfläche. Ein To-do ist eine gewöhnliche Notiz
 * mit Erledigt-Stand; seine Unteraufgaben sind die Checklisten-Zeilen (`- [ ] ` / `- [x] `) ihres Textes. Format und
 * Regeln stehen in `DESIGN.md`, Abschnitt „To-dos“; `TodosTest` prüft dieselben Fälle wie `TodosTests.swift`.
 */
object Todos {
    /** Eine Checklisten-Zeile des Textes. [line]: Index der Zeile (Text an "\n" geteilt). */
    data class Subtask(val line: Int, val indent: Int, val text: String, val done: Boolean)

    data class Progress(val done: Int, val total: Int) {
        /** Jede Unteraufgabe abgehakt (und es gibt mindestens eine). */
        val isComplete: Boolean get() = total > 0 && done == total
        val hasOpen: Boolean get() = done < total
        /** "2/5"; leer ohne Unteraufgaben. */
        val label: String get() = if (total == 0) "" else "$done/$total"
    }

    private val checklistMark = Regex("""^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+(.*))?$""")
    private val box = Regex("""\[[ xX]\]""")

    /** Wie Swifts `.whitespaces`: Leerzeichen aller Art und Tab, keine Zeilenumbrüche. */
    private fun String.trimSpaces() = trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }

    /** Die Unteraufgaben: Checklisten-Zeilen mit Text, außerhalb von Code-Blöcken. Dieselbe Syntax wie der Editor. */
    fun subtasks(text: String): List<Subtask> {
        if ('[' !in text) return emptyList()
        val result = mutableListOf<Subtask>()
        var inFence = false
        text.split("\n").forEachIndexed { index, line ->
            if (line.trimSpaces().startsWith("```")) {
                inFence = !inFence
                return@forEachIndexed
            }
            if (inFence) return@forEachIndexed
            val item = checklistItem(line) ?: return@forEachIndexed
            val body = item.third.trimSpaces()
            if (body.isEmpty()) return@forEachIndexed
            result += Subtask(index, item.first, body, item.second)
        }
        return result
    }

    /** Einrückung, abgehakt, Text — oder null, wenn die Zeile keine Checklisten-Zeile ist. */
    private fun checklistItem(line: String): Triple<Int, Boolean, String>? {
        val match = checklistMark.find(line) ?: return null
        val space = match.groupValues[1]
        val indent = space.sumOf { if (it == '\t') 2 else 1 } / 2
        return Triple(indent, match.groupValues[2] != " ", match.groups[3]?.value ?: "")
    }

    fun progress(text: String): Progress {
        val items = subtasks(text)
        return Progress(items.count { it.done }, items.size)
    }

    /** Die Zeile mit abgehakter oder offener Box; andere Zeilen bleiben, wie sie sind. */
    fun setLine(line: Int, done: Boolean, text: String): String {
        val lines = text.split("\n").toMutableList()
        if (line !in lines.indices || checklistItem(lines[line]) == null) return text
        val range = box.find(lines[line])?.range ?: return text
        lines[line] = lines[line].replaceRange(range, if (done) "[x]" else "[ ]")
        return lines.joinToString("\n")
    }

    fun toggleLine(line: Int, text: String): String {
        val item = subtasks(text).firstOrNull { it.line == line } ?: return text
        return setLine(line, !item.done, text)
    }

    /** Jede Unteraufgabe abgehakt (oder offen). */
    fun setAll(done: Boolean, text: String): String = subtasks(text).fold(text) { acc, item -> setLine(item.line, done, acc) }

    /** Eine neue offene Unteraufgabe am Ende; eine leere Checklisten-Zeile dort wird wiederverwendet. */
    fun appendingSubtask(title: String = "", text: String): String {
        val lines = if (text.isEmpty()) mutableListOf() else text.split("\n").toMutableList()
        val last = lines.lastOrNull()
        if (last != null) {
            val item = checklistItem(last)
            if (item != null && item.third.trimSpaces().isEmpty()) lines.removeAt(lines.lastIndex)
        }
        while (lines.lastOrNull()?.trimSpaces()?.isEmpty() == true) lines.removeAt(lines.lastIndex)
        lines += "- [ ] $title"
        return lines.joinToString("\n")
    }

    /** Schiebt eine Zeile eine Stelle hoch (-1) oder runter (+1). */
    fun moveLine(line: Int, offset: Int, text: String): String {
        val lines = text.split("\n").toMutableList()
        val target = line + offset
        if (line !in lines.indices || target !in lines.indices) return text
        lines[line] = lines[target].also { lines[target] = lines[line] }
        return lines.joinToString("\n")
    }

    fun removeLine(line: Int, text: String): String {
        val lines = text.split("\n").toMutableList()
        if (line !in lines.indices) return text
        lines.removeAt(line)
        return lines.joinToString("\n")
    }

    // Erledigt-Regeln

    /**
     * Was der Stand wird, nachdem sich die Unteraufgaben von [old] zu [new] geändert haben (null: er bleibt).
     * Die letzte offene abgehakt: erledigt. Ein erledigtes bekommt eine offene (eine abgewählte oder eine neue): wieder
     * offen. Nur Änderungen zählen: von Hand wieder geöffnet mit allem abgehakt bleibt offen.
     */
    fun stateAfterEdit(old: String, new: String, state: TodoState): TodoState? {
        val before = progress(old)
        val after = progress(new)
        if (before == after) return null
        if (state == TodoState.OPEN && after.isComplete && !before.isComplete) return TodoState.DONE
        if (state == TodoState.DONE && after.hasOpen && (!before.hasOpen || after.done < before.done)) return TodoState.OPEN
        return null
    }

    // Sync

    /** Schlüssel einer Unteraufgabe über Fassungen hinweg: ihre Wörter und wie viele Zeilen mit denselben Wörtern davor kamen. */
    private fun keyed(text: String): Map<String, Subtask> {
        val seen = HashMap<String, Int>()
        val result = LinkedHashMap<String, Subtask>()
        for (item in subtasks(text)) {
            val words = item.text.lowercase()
            val n = seen[words] ?: 0
            seen[words] = n + 1
            result["$n|$words"] = item
        }
        return result
    }

    /**
     * Drei-Wege-Abgleich der Haken, wenn beide Geräte ein To-do geändert haben: der Text von [winner] (der neuere) mit
     * den Unteraufgaben, die das andere Gerät seit [base] abgehakt oder abgewählt hat, solange der neuere sie ließ.
     */
    fun mergeTicks(base: String, winner: String, loser: String): String {
        val baseItems = keyed(base)
        val winnerItems = keyed(winner)
        var text = winner
        for ((key, theirs) in keyed(loser)) {
            val was = baseItems[key] ?: continue
            if (theirs.done == was.done) continue
            val mine = winnerItems[key] ?: continue
            if (mine.done != was.done) continue
            text = setLine(mine.line, theirs.done, text)
        }
        return text
    }

    /**
     * Der Eintrag eines To-dos, das auf beiden Geräten geändert wurde: der neuere mit den Haken des anderen (siehe
     * [mergeTicks]), sein Stand folgt den zusammengeführten Unteraufgaben. Null, wenn nichts zusammenzuführen ist.
     */
    fun mergeRecords(base: String?, winner: JsonObject, loser: JsonObject, now: Long): JsonObject? {
        if (base == null || !isTodoRecord(winner) || !isTodoRecord(loser)) return null
        val winnerText = (winner["text"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val loserText = (loser["text"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val text = mergeTicks(base, winnerText, loserText)
        if (text == winnerText) return null
        val merged = winner.toMutableMap()
        merged["text"] = JsonPrimitive(text)
        val state = TodoState.of(stringField(winner, "todoStateRaw")) ?: TodoState.OPEN
        when (stateAfterEdit(winnerText, text, state)) {
            TodoState.DONE -> {
                merged["todoStateRaw"] = JsonPrimitive(TodoState.DONE.raw)
                merged["todoDoneAt"] = JsonPrimitive(now)
            }
            TodoState.OPEN -> {
                merged["todoStateRaw"] = JsonPrimitive(TodoState.OPEN.raw)
                merged.remove("todoDoneAt")
            }
            else -> Unit
        }
        return JsonObject(merged)
    }

    /** Der Eintrag ist der eines To-dos (offen oder erledigt). */
    fun isTodoRecord(record: JsonObject): Boolean {
        val raw = stringField(record, "todoStateRaw")
        return raw == TodoState.OPEN.raw || raw == TodoState.DONE.raw
    }

    /** Der Text eines To-do-Eintrags als Grundlage des nächsten Abgleichs der Haken (`SyncBase.text`); sonst null. */
    fun baseText(record: JsonObject): String? = if (isTodoRecord(record)) stringField(record, "text") else null

    private fun stringField(record: JsonObject, key: String): String? =
        (record[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    // Listen

    /** Ein erledigtes To-do bleibt für den Rest des Tages in seiner Liste, abgehakt; ab dem nächsten Tag gilt es als archiviert. */
    fun isPutAway(doneAt: Long?, now: Long = System.currentTimeMillis()): Boolean {
        if (doneAt == null) return false
        val startOfDay = Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        return doneAt < startOfDay
    }

    // Die Notiz als To-do (iOS: `extension Todos` mit ModelContext; hier rein, gespeichert über `NoteStore`)

    /** Macht aus einer Notiz ein To-do (offen) oder wieder eine Notiz ("none"). Der Text bleibt. Null: nichts zu tun. */
    fun withTodo(note: Note, isTodo: Boolean): Note? {
        if (isTodo == note.isTodo) return null
        return note.copy(todoStateRaw = if (isTodo) TodoState.OPEN.raw else TodoState.NONE.raw, todoDoneAt = null)
    }

    /** Hakt das To-do selbst ab oder öffnet es. Erledigt hakt jede Unteraufgabe ab; offen lässt sie, wie sie sind. */
    fun withDone(note: Note, done: Boolean, now: Long = System.currentTimeMillis()): Note? {
        if (!note.isTodo || done == note.isDone) return null
        return note.copy(
            todoStateRaw = if (done) TodoState.DONE.raw else TodoState.OPEN.raw,
            todoDoneAt = if (done) now else null,
            text = if (done) setAll(true, note.text) else note.text,
        )
    }

    /** Hakt eine Unteraufgabe ab oder ab; das To-do folgt ([stateAfterEdit]). */
    fun withToggledSubtask(note: Note, line: Int, now: Long = System.currentTimeMillis()): Note =
        following(note.copy(text = toggleLine(line, note.text)), note.text, now)

    /** Der Text eines To-dos wurde bearbeitet (eine Box im Editor, eine neue Unteraufgabe): der Stand folgt. */
    fun following(note: Note, old: String, now: Long = System.currentTimeMillis()): Note {
        val state = note.todoState ?: return note
        if (!note.isTodo) return note
        val next = stateAfterEdit(old, note.text, state) ?: return note
        return note.copy(todoStateRaw = next.raw, todoDoneAt = if (next == TodoState.DONE) now else null)
    }

    /** Eine Aufgabenzeile einer Zusammenfassung als eigenes To-do, in den Buckets ihrer Notiz, mit Verweis zurück. Nie aus einem Link oder einer Datei. */
    fun fromTask(task: String, source: Note, now: Long = System.currentTimeMillis()): Note? {
        if (source.isSaved) return null
        return Note(
            title = task, titleIsCustom = true, sourceRaw = NoteSource.NOTE.raw,
            todoStateRaw = TodoState.OPEN.raw, todoSourceID = source.id,
            projectIDs = source.projectIDs, filedAt = if (source.projectIDs.isEmpty()) null else now,
            createdAt = now, updatedAt = now,
        )
    }

    /** Die To-dos aus den Aufgabenzeilen der Zusammenfassung einer Notiz. */
    fun madeFrom(source: Note, notes: List<Note>): List<Note> = notes.filter { it.todoSourceID == source.id && !it.isDeleted }

    /** iOS: `ChatRetrieval.todoLine` — "To-do, open, 1 of 3 subtasks done: Pack" oder "To-do, done on 19 Nov 2026: Pack". */
    fun chatLine(note: Note): String {
        var head = "To-do, " + if (note.isDone) "done" else "open"
        val at = note.todoDoneAt
        if (note.isDone && at != null) head += " on " + java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.getDefault()).format(java.util.Date(at))
        val progress = note.todoProgress
        if (progress.total > 0) head += ", ${progress.done} of ${progress.total} subtasks done"
        return head + ": " + note.displayTitle
    }
}

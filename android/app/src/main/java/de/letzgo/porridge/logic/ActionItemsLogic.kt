package de.letzgo.porridge.logic

import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import java.text.DateFormat
import java.util.Date

/**
 * iOS: `ActionItems` (Services/ActionItems.swift) — nimmt Aufgaben und Entscheidungen aus einer
 * Zusammenfassung: die Abschnitte „Action Items“/„Decisions“ (in jeder Sprache) und Checklisten-Zeilen
 * überall. Abhaken eines Eintrags hakt auch seine Zeile in der Zusammenfassung ab. Hier nur die reine Logik;
 * das Speichern macht `store/ActionItemStore.kt`.
 */
object ActionItemsLogic {
    /** Eine Zeile der Zusammenfassung, die Aufgabe oder Entscheidung ist. */
    data class Parsed(
        val kind: ActionItem.Kind,
        val text: String,
        val owner: String?,
        val done: Boolean,
        /** Die Zeile ist eine `- [ ]`-Checkliste (ein einfacher Punkt unter der Aufgaben-Überschrift zählt auch). */
        val isCheckbox: Boolean,
        /** Index der Zeile in der Zusammenfassung. */
        val line: Int,
    ) {
        val key: String get() = key(kind, text, owner)
    }

    private enum class Section { NONE, TASKS, DECISIONS, OTHER }

    private val taskHeadings = listOf(
        "action item", "tasks", "task", "to-do", "todo", "next step", "aufgaben", "offene punkte", "nächste schritte",
        "actions à mener", "actions", "tareas", "attività", "acties", "tarefas", "zadania",
    )
    private val decisionHeadings = listOf(
        "decision", "entscheidung", "beschl", "décision", "decisione", "decisiones", "besluit", "decisõe", "decyzj",
    )

    fun parse(summary: String): List<Parsed> {
        val result = mutableListOf<Parsed>()
        var section = Section.NONE
        summary.split("\n").forEachIndexed { index, raw ->
            val line = raw.trim(' ', '\t')
            if (line.isEmpty()) return@forEachIndexed
            if (line.startsWith("#")) {
                section = classify(line.dropWhile { it == '#' }.trim(' ', '\t'))
                return@forEachIndexed
            }
            val bullet = bullet(line) ?: return@forEachIndexed
            var body = line.drop(bullet.length).trim(' ', '\t')
            var done = false
            var isCheckbox = false
            for ((mark, value) in listOf("[ ]" to false, "[x]" to true, "[X]" to true)) {
                if (body.startsWith(mark)) {
                    body = body.drop(mark.length).trim(' ', '\t')
                    done = value
                    isCheckbox = true
                }
            }
            body = body.replace("**", "").trim(' ', '\t')
            if (body.isEmpty() || saysNone(body)) return@forEachIndexed
            if (isCheckbox || section == Section.TASKS) {
                val (text, owner) = splitOwner(body)
                result += Parsed(ActionItem.Kind.TASK, text, owner, done, isCheckbox, index)
            } else if (section == Section.DECISIONS) {
                result += Parsed(ActionItem.Kind.DECISION, body, null, false, false, index)
            }
        }
        return result
    }

    /** „Keine Aufgaben genannt.“ / „No action items.“ ist keine Aufgabe. */
    private fun saysNone(body: String): Boolean {
        val text = body.lowercase()
        if (text.length > 60) return false
        return listOf("keine ", "no ", "none", "aucun", "ningun", "nessun", "geen ", "nenhum", "brak ").any { text.startsWith(it) } &&
            listOf("aufgabe", "task", "action", "entscheid", "decision", "none", "décision", "tarea", "decisi", "actie", "besluit", "tarefa", "zadani", "decyz", "offen", "open").any { it in text }
    }

    private fun classify(heading: String): Section {
        val name = heading.lowercase()
        return when {
            taskHeadings.any { it in name } -> Section.TASKS
            decisionHeadings.any { it in name } -> Section.DECISIONS
            else -> Section.OTHER
        }
    }

    /** Das Listenzeichen am Zeilenanfang („- “, „1. “) oder null für einen Absatz. */
    internal fun bullet(line: String): String? {
        for (mark in listOf("- ", "* ", "• ", "+ ")) if (line.startsWith(mark)) return mark
        val digits = line.takeWhile { it.isDigit() }
        if (digits.isNotEmpty() && digits.length <= 3 && line.drop(digits.length).startsWith(". ")) return line.take(digits.length + 2)
        return null
    }

    /** „Aufgabe – Anna“ → („Aufgabe“, „Anna“). Nur ein kurzer Rest nach einem Strich zählt als Zuständiger. */
    fun splitOwner(body: String): Pair<String, String?> {
        for (dash in listOf(" – ", " — ", " - ")) {
            val at = body.lastIndexOf(dash)
            if (at < 0) continue
            val text = body.substring(0, at).trim(' ', '\t')
            val tail = body.substring(at + dash.length).trim(' ', '\t').trim('.', ';')
            if (text.isNotEmpty() && tail.isNotEmpty() && tail.length <= 40 && ". " !in tail && tail.split(" ").filter { it.isNotEmpty() }.size <= 4) {
                return text to tail
            }
        }
        return body to null
    }

    fun key(kind: ActionItem.Kind, text: String, owner: String?): String {
        val words = (text + " " + (owner ?: "")).lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        return kind.raw + ":" + words.joinToString(" ")
    }

    fun key(item: ActionItem) = key(item.kind, item.text, item.owner)

    /** Woran eine Zusammenfassungs-Zeile den Eintrag erkennt: die Zeile, aus der er entstand, auch nach Umbenennen. */
    fun matchKey(item: ActionItem) = item.summaryKey ?: key(item)

    /** Nichts von Hand geändert: noch der Wortlaut der Zusammenfassung, kein eigener Text, nicht abgehakt. */
    fun isUntouched(item: ActionItem) = item.details.isBlank() && !item.isDone && key(item) == matchKey(item)

    /** Was [sync] am Speicher ändern will. */
    data class SyncPlan(val upserts: List<ActionItem>, val deletes: List<ActionItem>) {
        val isEmpty get() = upserts.isEmpty() && deletes.isEmpty()
    }

    /**
     * iOS: `ActionItems.sync` — bringt die Einträge einer Notiz in Einklang mit ihrer Zusammenfassung: neue
     * Zeilen werden Einträge, abgehakte Zeilen haken ihren Eintrag ab. Eine verschwundene Zeile nimmt ihren
     * Eintrag nur mit, solange niemand ihn angefasst hat; ein bearbeiteter, abgehakter oder beschriebener
     * Eintrag bleibt als eigenständige Aufgabe ("kept"). Eine gespeicherte Seite gibt nie Aufgaben.
     */
    fun sync(note: Note, existing: List<ActionItem>, now: Long = System.currentTimeMillis()): SyncPlan {
        val parsed = if (note.isLink) emptyList() else parse(note.summary.orEmpty())
        val remaining = LinkedHashMap<String, ArrayDeque<ActionItem>>()
        // Wie iOS: unter Kopien gleichen Wortlauts gewinnt die kleinste id (Kopien entstehen dort durch iCloud).
        for (item in existing.filter { it.isFromSummary }.sortedWith(compareBy<ActionItem> { it.order }.thenBy { it.id })) {
            remaining.getOrPut(matchKey(item)) { ArrayDeque() }.addLast(item)
        }
        for (list in remaining.values) { val sorted = list.sortedBy { it.id }; list.clear(); list.addAll(sorted) }
        val upserts = mutableListOf<ActionItem>()
        parsed.forEachIndexed { order, line ->
            val list = remaining[line.key]
            val found = list?.removeFirstOrNull()
            var item = found ?: ActionItem(
                noteID = note.id, kindRaw = line.kind.raw, text = line.text, owner = line.owner,
                summaryKey = line.key, createdAt = note.summarizedAt ?: now,
                // Eine neue Aufgabe wartet unter „New“, bis sie übernommen wird; eine abgehakte ist schon erledigt.
                reviewRaw = (if (line.kind == ActionItem.Kind.TASK && !line.done) ActionItem.Review.PENDING else ActionItem.Review.ACCEPTED).raw,
            )
            var changed = found == null
            // Eine anderswo abgehakte Kopie zählt.
            val copy = list?.firstOrNull { it.isDone }
            if (copy != null && !item.isDone && !line.isCheckbox) { item = item.copy(isDone = true, doneAt = copy.doneAt); changed = true }
            if (item.order != order) { item = item.copy(order = order); changed = true }
            if (line.isCheckbox && item.isDone != line.done) {
                item = item.copy(isDone = line.done, doneAt = if (line.done) now else null)
                changed = true
            }
            if (changed) upserts += item
        }
        val deletes = mutableListOf<ActionItem>()
        for (item in remaining.values.flatten()) {
            if (isUntouched(item) || note.isLink) deletes += item else upserts += item.copy(source = "kept")
        }
        return SyncPlan(upserts, deletes)
    }

    /**
     * iOS: Zusammenfassungs-Teil von `ActionItems.setDone` — die neue Zusammenfassung, wenn [item] als
     * [done] markiert wird; der n-te Eintrag mit gleichem Wortlaut hakt die n-te Zeile damit ab.
     */
    fun summaryAfterSetDone(summary: String, item: ActionItem, done: Boolean, siblings: List<ActionItem>): String {
        if (!item.isFromSummary) return summary
        val target = matchKey(item)
        val position = siblings.filter { it.isFromSummary && matchKey(it) == target }.sortedBy { it.order }.indexOfFirst { it.id == item.id }.coerceAtLeast(0)
        val matches = parse(summary).filter { it.key == target }
        if (position >= matches.size) return summary
        val line = matches[position]
        val lines = summary.split("\n").toMutableList()
        lines[line.line] = ticked(lines[line.line], done, line.isCheckbox)
        return lines.joinToString("\n")
    }

    private fun ticked(line: String, done: Boolean, isCheckbox: Boolean): String {
        if (isCheckbox) {
            for (mark in listOf("[ ]", "[x]", "[X]")) {
                val at = line.indexOf(mark)
                if (at >= 0) return line.replaceRange(at, at + mark.length, if (done) "[x]" else "[ ]")
            }
            return line
        }
        // Ein einfacher Punkt unter der Aufgaben-Überschrift wird beim Abhaken zur Checkliste.
        val indent = line.takeWhile { it == ' ' || it == '\t' }
        val rest = line.drop(indent.length)
        val mark = bullet(rest) ?: return line
        return indent + "- " + (if (done) "[x] " else "[ ] ") + rest.drop(mark.length)
    }

    /** iOS: `AppSettings.myNames` — die Namen des Nutzers, klein geschrieben; leer, wenn keiner gesetzt ist. */
    fun myNames(raw: String?): List<String> = raw.orEmpty().split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }

    /**
     * iOS: `isMine` — eine Aufgabe gehört dem Nutzer, wenn ihr Zuständiger einer seiner Namen ist („Anna“ passt auch
     * zu „Anna Berg“ und „Anna, Ben“), oder wenn niemand genannt ist und sie seine eigene ist: von Hand angelegt oder
     * aus einer Notiz, die er geschrieben hat (keine Aufnahme, dort könnte sie jedem gehören).
     */
    fun isMine(item: ActionItem, note: Note?, names: List<String>): Boolean {
        val owner = item.owner?.lowercase()?.takeIf { it.isNotBlank() }
            ?: return item.source == "manual" || (note != null && !note.isRecording)
        val parts = owner.replace(" und ", ",").replace(" and ", ",").split(',', '&', '/', '+').map { it.trim() }
        return parts.any { isMe(it, names) }
    }

    /** iOS: `AppSettings.isMe` — ob ein Sprecher- oder Zuständigen-Name der Nutzer ist: ganzer Name oder Vorname einer Seite. */
    fun isMe(name: String, names: List<String>): Boolean {
        val value = name.trim().lowercase()
        if (value.isEmpty()) return false
        return names.any { mine -> value == mine || value.split(" ").first() == mine || mine.split(" ").first() == value }
    }

    /** iOS: `contextBlock` — offene Aufgaben und Entscheidungen als Text für das Modell, neueste Notiz zuerst. */
    fun contextBlock(items: List<ActionItem>, notes: List<Note>, limit: Int): String {
        val byID = notes.associateBy { it.id }
        val format = DateFormat.getDateInstance(DateFormat.MEDIUM)
        fun line(item: ActionItem): String? {
            val details = item.details.trim()
            val more = if (details.isEmpty()) "" else "\n  " + details.take(240).replace("\n", " ")
            val note = item.noteID?.let { byID[it] }
                ?: return "- ${item.line} (task of its own, ${format.format(Date(item.createdAt))})" + more
            if (note.isDeleted) return null
            return "- ${item.line} («${note.displayTitle}», ${format.format(Date(note.createdAt))})" + more
        }
        val dated = items.mapNotNull { item ->
            if (item.review == ActionItem.Review.DISMISSED) return@mapNotNull null
            val note = item.noteID?.let { byID[it] } ?: return@mapNotNull item.createdAt to item
            if (note.isDeleted || note.isLink) null else note.createdAt to item
        }.sortedByDescending { it.first }.map { it.second }
        val open = dated.filter { it.kind == ActionItem.Kind.TASK && !it.isDone }.mapNotNull(::line)
        val done = dated.filter { it.kind == ActionItem.Kind.TASK && it.isDone }.take(10).mapNotNull(::line)
        val decisions = dated.filter { it.kind == ActionItem.Kind.DECISION }.mapNotNull(::line)
        val text = StringBuilder()
        fun add(title: String, lines: List<String>) {
            if (lines.isEmpty()) return
            val block = StringBuilder(title).append("\n")
            for (entry in lines) if (text.length + block.length + entry.length < limit) block.append(entry).append("\n")
            text.append(block).append("\n")
        }
        add("Open tasks (from the summaries, with the note they come from):", open)
        add("Done tasks (recent):", done)
        add("Decisions (from the summaries):", decisions)
        return text.toString()
    }
}

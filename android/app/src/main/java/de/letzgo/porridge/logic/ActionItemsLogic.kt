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

    /** Was [sync] am Speicher ändern will. */
    data class SyncPlan(val upserts: List<ActionItem>, val deletes: List<ActionItem>) {
        val isEmpty get() = upserts.isEmpty() && deletes.isEmpty()
    }

    /**
     * iOS: `ActionItems.sync` — bringt die Einträge einer Notiz in Einklang mit ihrer Zusammenfassung: neue
     * Zeilen werden Einträge, abgehakte Zeilen haken ihren Eintrag ab, verschwundene Zeilen nehmen ihren
     * Eintrag mit. In der App abgehakte Einträge behalten ihren Stand, solange ihre Zeile ein einfacher Punkt ist.
     */
    fun sync(note: Note, existing: List<ActionItem>, now: Long = System.currentTimeMillis()): SyncPlan {
        val parsed = parse(note.summary.orEmpty())
        val remaining = LinkedHashMap<String, ArrayDeque<ActionItem>>()
        for (item in existing.filter { it.isFromSummary }.sortedBy { it.order }) {
            remaining.getOrPut(key(item)) { ArrayDeque() }.addLast(item)
        }
        val upserts = mutableListOf<ActionItem>()
        parsed.forEachIndexed { order, line ->
            val found = remaining[line.key]?.removeFirstOrNull()
            var item = found ?: ActionItem(
                noteID = note.id, kindRaw = line.kind.raw, text = line.text, owner = line.owner,
                createdAt = note.summarizedAt ?: now,
            )
            var changed = found == null
            if (item.order != order) { item = item.copy(order = order); changed = true }
            if (line.isCheckbox && item.isDone != line.done) {
                item = item.copy(isDone = line.done, doneAt = if (line.done) now else null)
                changed = true
            }
            if (changed) upserts += item
        }
        return SyncPlan(upserts, remaining.values.flatten())
    }

    /**
     * iOS: Zusammenfassungs-Teil von `ActionItems.setDone` — die neue Zusammenfassung, wenn [item] als
     * [done] markiert wird; der n-te Eintrag mit gleichem Wortlaut hakt die n-te Zeile damit ab.
     */
    fun summaryAfterSetDone(summary: String, item: ActionItem, done: Boolean, siblings: List<ActionItem>): String {
        if (!item.isFromSummary) return summary
        val target = key(item)
        val position = siblings.filter { key(it) == target }.sortedBy { it.order }.indexOfFirst { it.id == item.id }.coerceAtLeast(0)
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

    /** iOS: `contextBlock` — offene Aufgaben und Entscheidungen als Text für das Modell, neueste Notiz zuerst. */
    fun contextBlock(items: List<ActionItem>, notes: List<Note>, limit: Int): String {
        val byID = notes.associateBy { it.id }
        val format = DateFormat.getDateInstance(DateFormat.MEDIUM)
        fun line(item: ActionItem): String? {
            val note = item.noteID?.let { byID[it] }?.takeIf { !it.isDeleted } ?: return null
            return "- ${item.line} («${note.displayTitle}», ${format.format(Date(note.createdAt))})"
        }
        val dated = items.mapNotNull { item ->
            val note = item.noteID?.let { byID[it] }?.takeIf { !it.isDeleted } ?: return@mapNotNull null
            note.createdAt to item
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

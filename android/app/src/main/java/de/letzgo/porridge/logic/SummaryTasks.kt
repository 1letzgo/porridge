package de.letzgo.porridge.logic

/**
 * iOS: `SummaryTasks.parse` (Services/SummaryTasks.swift) — die Aufgabenzeilen einer Zusammenfassung: jede Checkbox-Zeile
 * und jeder Listenpunkt unter einer Überschrift für Aufgaben. „Keine Aufgaben“ ist keine.
 */
object SummaryTasks {
    /** Eine Zeile der Zusammenfassung, die eine Aufgabe ist. [line]: Index der Zeile. */
    data class Parsed(val text: String, val done: Boolean, val isCheckbox: Boolean, val line: Int)

    private enum class Section { NONE, TASKS, OTHER }

    private val taskHeadings = listOf(
        "action item", "tasks", "task", "to-do", "todo", "next step", "aufgaben", "offene punkte", "nächste schritte",
        "actions à mener", "actions", "tareas", "attività", "acties", "tarefas", "zadania",
    )

    /** Wie Swifts `.whitespaces`: Leerzeichen aller Art und Tab. */
    private fun String.trimSpaces() = trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }

    fun parse(summary: String): List<Parsed> {
        val result = mutableListOf<Parsed>()
        var section = Section.NONE
        summary.split("\n").forEachIndexed { index, raw ->
            val line = raw.trimSpaces()
            if (line.isEmpty()) return@forEachIndexed
            if (line.startsWith("#")) {
                section = classify(line.dropWhile { it == '#' }.trimSpaces())
                return@forEachIndexed
            }
            val bullet = bullet(line) ?: return@forEachIndexed
            var body = line.drop(bullet.length).trimSpaces()
            var done = false
            var isCheckbox = false
            for ((mark, value) in listOf("[ ]" to false, "[x]" to true, "[X]" to true)) {
                if (body.startsWith(mark)) {
                    body = body.drop(mark.length).trimSpaces()
                    done = value
                    isCheckbox = true
                }
            }
            body = body.replace("**", "").trimSpaces()
            if (body.isEmpty() || saysNone(body)) return@forEachIndexed
            if (isCheckbox || section == Section.TASKS) result += Parsed(body, done, isCheckbox, index)
        }
        return result
    }

    /** "Keine Aufgaben genannt." / "No action items." ist keine Aufgabe. */
    private fun saysNone(body: String): Boolean {
        val text = body.lowercase()
        if (text.length > 60) return false
        return listOf("keine ", "no ", "none", "aucun", "ningun", "nessun", "geen ", "nenhum", "brak ").any { text.startsWith(it) } &&
            listOf("aufgabe", "task", "action", "none", "tarea", "actie", "tarefa", "zadani", "offen", "open").any { text.contains(it) }
    }

    private fun classify(heading: String): Section {
        val name = heading.lowercase()
        return if (taskHeadings.any { name.contains(it) }) Section.TASKS else Section.OTHER
    }

    /** Das Listenzeichen am Zeilenanfang ("- ", "1. "), oder null für einen Absatz. */
    private fun bullet(line: String): String? {
        for (mark in listOf("- ", "* ", "• ", "+ ")) if (line.startsWith(mark)) return mark
        val digits = line.takeWhile { it.isDigit() }
        if (digits.isNotEmpty() && digits.length <= 3 && line.drop(digits.length).startsWith(". ")) return line.take(digits.length + 2)
        return null
    }
}

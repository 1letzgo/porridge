package de.letzgo.porridge.logic

/** iOS: `SummaryChecklist` — Aufgaben stehen nur in der Zusammenfassung; Abhaken ändert dort den Text der Zeile. */
object SummaryChecklist {
    /** Die Zusammenfassung mit umgeschalteter Checkbox in Zeile [line], oder null, wenn dort keine steht. */
    fun toggled(summary: String, line: Int): String? {
        val lines = summary.split("\n").toMutableList()
        val text = lines.getOrNull(line) ?: return null
        val match = Regex("""^(\s*(?:[-*+•]|\d{1,3}\.)\s+)\[([ xX])]""").find(text) ?: return null
        val mark = if (match.groupValues[2] == " ") "[x]" else "[ ]"
        lines[line] = match.groupValues[1] + mark + text.substring(match.range.last + 1)
        return lines.joinToString("\n")
    }
}

package de.letzgo.porridge.logic.editor

import kotlin.math.min

/**
 * iOS: `NoteBlock` (Views/Notes/NoteBlocks.swift) — eine Zeile einer Notiz. Die Notiz bleibt Markdown (Suche, Tags,
 * Zusammenfassungen); der Editor zeigt Absätze und schreibt nach jeder Änderung wieder Markdown.
 */
data class NoteBlock(val kind: Kind = Kind.Paragraph, val indent: Int = 0, val text: String = "") {
    sealed interface Kind {
        data object Paragraph : Kind
        /** 1 = Titel, 2 = Überschrift, 3 = Unterüberschrift. */
        data class Heading(val level: Int) : Kind
        data object Bullet : Kind
        data object Numbered : Kind
        data class Checklist(val checked: Boolean) : Kind
        data object Quote : Kind

        val isList: Boolean get() = this == Bullet || this == Numbered || this is Checklist
        val headingLevel: Int get() = (this as? Heading)?.level ?: 0
    }

    val isList: Boolean get() = kind.isList

    /** Das Markdown-Zeichen vor dem Text, mit Einrückung. */
    fun mark(number: Int): String {
        val space = "  ".repeat(indent)
        return when (kind) {
            Kind.Paragraph -> ""
            is Kind.Heading -> "#".repeat(kind.level) + " "
            Kind.Bullet -> "$space- "
            Kind.Numbered -> "$space$number. "
            is Kind.Checklist -> space + if (kind.checked) "- [x] " else "- [ ] "
            Kind.Quote -> "> "
        }
    }

    companion object {
        const val MAX_INDENT = 4

        private val headingMark = Regex("""^(#{1,3})[ \t]+(.*)$""")
        private val checklistMark = Regex("""^([ \t]*)[-*+][ \t]+\[([ xX])](?:[ \t]+(.*))?$""")
        private val bulletMark = Regex("""^([ \t]*)[-*+][ \t]+(.*)$""")
        private val numberMark = Regex("""^([ \t]*)\d{1,3}[.)][ \t]+(.*)$""")
        private val quoteMark = Regex("""^>[ \t]?(.*)$""")

        private fun level(space: String) = min(MAX_INDENT, space.fold(0) { acc, c -> acc + if (c == '\t') 2 else 1 } / 2)

        /** Eine Markdown-Zeile als Block. Was keine Liste, Überschrift oder Zitat ist, bleibt eine Zeile. */
        fun parseLine(line: String): NoteBlock {
            headingMark.matchEntire(line)?.let { return NoteBlock(Kind.Heading(it.groupValues[1].length), text = it.groupValues[2]) }
            checklistMark.matchEntire(line)?.let {
                return NoteBlock(Kind.Checklist(it.groupValues[2] != " "), level(it.groupValues[1]), it.groupValues[3])
            }
            bulletMark.matchEntire(line)?.let { return NoteBlock(Kind.Bullet, level(it.groupValues[1]), it.groupValues[2]) }
            numberMark.matchEntire(line)?.let { return NoteBlock(Kind.Numbered, level(it.groupValues[1]), it.groupValues[2]) }
            quoteMark.matchEntire(line)?.let { return NoteBlock(Kind.Quote, text = it.groupValues[1]) }
            return NoteBlock(text = line)
        }

        fun parse(markdown: String): List<NoteBlock> = markdown.split("\n").map(::parseLine)

        /** Die Nummer jedes nummerierten Blocks (0 für andere); die Zählung beginnt nach jedem anderen Block neu. */
        fun numbers(blocks: List<NoteBlock>): List<Int> {
            var counters = mutableMapOf<Int, Int>()
            return blocks.map { block ->
                counters = counters.filterKeys { it < block.indent }.toMutableMap()
                if (block.kind != Kind.Numbered) 0 else counters.merge(block.indent, 1, Int::plus)!!
            }
        }

        fun markdown(blocks: List<NoteBlock>): String {
            val numbers = numbers(blocks)
            return blocks.mapIndexed { i, block -> block.mark(numbers[i]) + block.text }.joinToString("\n")
        }

        /** Zeichenposition im Markdown, an der der Text eines Blocks beginnt. */
        fun textOffset(index: Int, blocks: List<NoteBlock>): Int {
            val numbers = numbers(blocks)
            var offset = 0
            blocks.forEachIndexed { i, block ->
                val mark = block.mark(numbers[i])
                if (i == index) return offset + mark.length
                offset += mark.length + block.text.length + 1
            }
            return offset
        }
    }
}

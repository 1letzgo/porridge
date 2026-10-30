package de.letzgo.porridge.logic.editor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteEditorEngineTest {
    private val buffer = MemoryBuffer()
    private var saved = ""
    private val engine = NoteEditorEngine(buffer) { saved = it }

    /** Tippt wie eine Tastatur: erst fragt der Editor die Engine, sonst ersetzt er selbst und meldet die Änderung. */
    private fun type(text: String) {
        for (c in text) replace(buffer.selectionStart, buffer.selectionEnd, c.toString())
    }

    private fun replace(start: Int, end: Int, replacement: String) {
        if (engine.shouldChange(start, end, replacement)) {
            buffer.replace(start, end, if (replacement.isEmpty()) emptyList() else listOf(StyledText(replacement, buffer.typingStyle)))
            buffer.selectionStart = start + replacement.length
            buffer.selectionEnd = buffer.selectionStart
            engine.didChange()
            engine.selectionChanged()
        } else {
            engine.selectionChanged()
        }
    }

    private fun backspace() {
        val at = buffer.selectionStart
        if (at > 0) replace(at - 1, at, "")
    }

    @Test fun markdownRoundTrip() {
        val md = "# Titel\nText **fett** und *kursiv* #tag\n- a\n  - b\n1. eins\n2. zwei\n- [x] erledigt\n- [ ] offen\n> Zitat\n"
        engine.load(md)
        assertEquals(md, engine.markdown())
        assertTrue(buffer.text.contains("•\t") && buffer.text.contains("2.\t") && buffer.text.contains(NoteMarkdown.CHECKBOX))
    }

    @Test fun unpairedStarsStayText() {
        engine.load("2*3 = 6 und **halb")
        assertEquals("2*3 = 6 und **halb", engine.markdown())
    }

    @Test fun bulletShortcutReturnAndEndingTheList() {
        engine.load("")
        type("- Milch\nBrot\n\nWeiter")
        assertEquals("- Milch\n- Brot\nWeiter", saved)
    }

    @Test fun numberingCountsOn() {
        engine.load("")
        type("1. eins\nzwei\nDrei")
        assertEquals("1. eins\n2. zwei\n3. Drei", saved)
        assertTrue(buffer.text.contains("3.\t"))
    }

    @Test fun backspaceRemovesTheMarkFirst() {
        engine.load("- a")
        buffer.selectionStart = buffer.length; buffer.selectionEnd = buffer.length
        backspace() // löscht „a“
        backspace() // ins Zeichen: Liste endet
        assertEquals("", saved)
        engine.load("Oben\n- unten")
        // Cursor an den Textanfang von „unten“ setzen.
        val at = buffer.text.indexOf("unten")
        buffer.selectionStart = at; buffer.selectionEnd = at
        backspace()
        assertEquals("Oben\nunten", saved)
    }

    @Test fun headingReturnGivesText() {
        engine.load("")
        type("## Plan\nText")
        assertEquals("## Plan\nText", saved)
    }

    @Test fun tabIndentsListItems() {
        engine.load("")
        type("- a\n\tb")
        assertEquals("- a\n  - b", saved)
        type("\n\n")
        assertEquals("- a\n  - b\n- ", saved)
    }

    @Test fun checklistShortcutAndTick() {
        engine.load("")
        type("[] Milch")
        assertEquals("- [ ] Milch", saved)
        assertTrue(engine.toggleCheckbox(0))
        assertEquals("- [x] Milch", saved)
        type("\nEier")
        assertEquals("- [x] Milch\n- [ ] Eier", saved)
    }

    @Test fun typingIntoAMarkerGoesAfterIt() {
        engine.load("- a")
        replace(0, 0, "x")
        assertEquals("- xa", saved)
    }

    @Test fun boldToggleOnWordAndSetKind() {
        engine.load("eins zwei drei")
        val at = buffer.text.indexOf("zwei") + 2
        buffer.selectionStart = at; buffer.selectionEnd = at
        engine.perform(NoteEditorCommand.ToggleInline("**"))
        assertEquals("eins **zwei** drei", saved)
        engine.perform(NoteEditorCommand.ToggleInline("**"))
        assertEquals("eins zwei drei", saved)
        engine.perform(NoteEditorCommand.SetKind(NoteBlock.Kind.Bullet))
        assertEquals("- eins zwei drei", saved)
        engine.perform(NoteEditorCommand.SetKind(NoteBlock.Kind.Bullet))
        assertEquals("eins zwei drei", saved)
    }

    @Test fun blocksMatchIOS() {
        val blocks = NoteBlock.parse("# T\n  - [x] a\n\t1) b\n> q\nx")
        assertEquals(NoteBlock.Kind.Heading(1), blocks[0].kind)
        assertEquals(NoteBlock(NoteBlock.Kind.Checklist(true), 1, "a"), blocks[1])
        assertEquals(NoteBlock(NoteBlock.Kind.Numbered, 1, "b"), blocks[2])
        assertEquals("# T\n  - [x] a\n  1. b\n> q\nx", NoteBlock.markdown(blocks))
        assertEquals(12, NoteBlock.textOffset(1, blocks))
    }
}

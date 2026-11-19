package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.TodoState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * iOS: `TodosTests` (PorridgeTests/TodosTests.swift) — dieselben Fälle mit denselben Antworten: To-dos sind Notizen mit
 * Erledigt-Stand, ihre Unteraufgaben die Checklisten-Zeilen des Textes.
 */
class TodosTest {
    private val text = listOf(
        "Before the trip",
        "- [ ] Passport",
        "- [x] Tickets",
        "  - [ ] Seat **window**",
        "- [ ]",
        "- plain bullet",
        "```",
        "- [ ] in code",
        "```",
    ).joinToString("\n")

    // Lesen

    @Test fun subtasksAreTheChecklistLinesWithText() {
        val items = Todos.subtasks(text)
        assertEquals(listOf("Passport", "Tickets", "Seat **window**"), items.map { it.text })
        assertEquals(listOf(1, 2, 3), items.map { it.line })
        assertEquals(listOf(false, true, false), items.map { it.done })
        assertEquals(listOf(0, 0, 1), items.map { it.indent })
        assertEquals(listOf(true, false), Todos.subtasks("* [X] Upper\n+ [ ] Plus").map { it.done })
    }

    @Test fun progress() {
        val progress = Todos.progress(text)
        assertEquals(Todos.Progress(1, 3), progress)
        assertEquals("1/3", progress.label)
        assertFalse(progress.isComplete)
        assertEquals("", Todos.progress("Just text").label)
        assertFalse(Todos.progress("").isComplete)
        assertTrue(Todos.progress("- [x] a\n- [X] b").isComplete)
    }

    // Bearbeiten

    @Test fun toggleChangesOnlyThatLine() {
        val toggled = Todos.toggleLine(1, text)
        assertTrue(toggled.contains("- [x] Passport"))
        assertEquals(text.split("\n").size, toggled.split("\n").size)
        assertEquals("  - [x] Seat **window**", Todos.toggleLine(3, text).split("\n")[3])
        // Keine Unteraufgabe: nichts ändert sich.
        assertEquals(text, Todos.toggleLine(0, text))
        assertEquals(text, Todos.toggleLine(7, text))
        assertEquals(text, Todos.toggleLine(99, text))
    }

    @Test fun setAllTicksEverySubtask() {
        assertTrue(Todos.progress(Todos.setAll(true, text)).isComplete)
        assertEquals(0, Todos.progress(Todos.setAll(false, text)).done)
        // Der Code-Block bleibt, wie er ist.
        assertTrue(Todos.setAll(true, text).contains("- [ ] in code"))
    }

    @Test fun addMoveRemove() {
        assertEquals("- [ ] Milk", Todos.appendingSubtask("Milk", ""))
        assertEquals("Shop\n- [ ] Milk", Todos.appendingSubtask("Milk", "Shop\n\n"))
        // Eine leere Checklisten-Zeile am Ende wird wiederverwendet, nicht verdoppelt.
        assertEquals("- [x] a\n- [ ] ", Todos.appendingSubtask(text = "- [x] a\n- [ ] "))
        val list = "- [ ] a\n- [ ] b\n- [ ] c"
        assertEquals("- [ ] a\n- [ ] c\n- [ ] b", Todos.moveLine(2, -1, list))
        assertEquals("- [ ] b\n- [ ] a\n- [ ] c", Todos.moveLine(0, 1, list))
        assertEquals(list, Todos.moveLine(0, -1, list))
        assertEquals("- [ ] a\n- [ ] c", Todos.removeLine(1, list))
    }

    // Erledigt-Regeln

    @Test fun tickingTheLastOpenSubtaskFinishesTheTodo() {
        val old = "- [x] a\n- [ ] b"
        assertEquals(TodoState.DONE, Todos.stateAfterEdit(old, "- [x] a\n- [x] b", TodoState.OPEN))
        assertNull(Todos.stateAfterEdit("- [ ] a\n- [ ] b", "- [x] a\n- [ ] b", TodoState.OPEN))
    }

    @Test fun anOpenSubtaskReopensADoneTodo() {
        val done = "- [x] a\n- [x] b"
        // Abgewählt.
        assertEquals(TodoState.OPEN, Todos.stateAfterEdit(done, "- [x] a\n- [ ] b", TodoState.DONE))
        // Dazugekommen.
        assertEquals(TodoState.OPEN, Todos.stateAfterEdit(done, "$done\n- [ ] c", TodoState.DONE))
        // Text geändert, Boxen gleich: bleibt.
        assertNull(Todos.stateAfterEdit(done, "- [x] a!\n- [x] b", TodoState.DONE))
    }

    @Test fun reopenedByHandWithEverythingTickedStaysOpen() {
        val done = "- [x] a\n- [x] b"
        assertNull(Todos.stateAfterEdit(done, "$done\nmore words", TodoState.OPEN))
    }

    @Test fun doneTicksAllAndTogglingFollows() {
        var note = Note(text = "- [ ] a\n- [ ] b")
        note = Todos.withTodo(note, true)!!
        assertEquals(TodoState.OPEN, note.todoState)
        assertTrue(note.isTodo)

        note = Todos.withToggledSubtask(note, 0)
        assertFalse(note.isDone)
        note = Todos.withToggledSubtask(note, 1)
        assertTrue(note.isDone)
        assertNotNull(note.todoDoneAt)

        note = Todos.withToggledSubtask(note, 1)
        assertFalse(note.isDone)
        assertNull(note.todoDoneAt)

        note = Todos.withDone(note, true)!!
        assertTrue(note.todoProgress.isComplete)
        // Wieder geöffnet bleiben die Unteraufgaben abgehakt.
        note = Todos.withDone(note, false)!!
        assertTrue(note.todoProgress.isComplete)
        assertFalse(note.isDone)

        // Zurück zur Notiz: "none" bleibt, damit die anderen Geräte davon erfahren; der Text bleibt.
        note = Todos.withTodo(note, false)!!
        assertEquals("none", note.todoStateRaw)
        assertFalse(note.isTodo)
        assertEquals("- [x] a\n- [x] b", note.text)
    }

    @Test fun doneTodosAreArchivedFromTheNextDay() {
        val now = System.currentTimeMillis()
        var note = Note(todoStateRaw = "done", todoDoneAt = now)
        assertFalse(note.isArchived)
        assertTrue(note.isInInbox)

        note = note.copy(todoDoneAt = now - 24L * 3600 * 1000)
        assertTrue(note.isPutAway)
        assertTrue(note.isArchived)
        assertFalse(note.isInInbox)
        assertEquals(listOf(note.id), HomeListLogic.archivedNotes(listOf(note)).map { it.id })
        // Aus dem Archiv geholt ist es wieder offen: `NoteStore.unarchive` (dieselbe Regel, geprüft über die Datenbank in der App).
    }

    @Test fun summaryTaskBecomesATodoInTheSameBuckets() {
        val meeting = Note(projectIDs = listOf("B1"), summary = "## Action Items\n- [ ] Send the offer")
        val todo = Todos.fromTask("Send the offer", meeting)!!
        assertEquals("Send the offer", todo.title)
        assertEquals(TodoState.OPEN, todo.todoState)
        assertEquals(listOf("B1"), todo.projectIDs)
        assertEquals(meeting.id, todo.todoSourceID)
        assertEquals(listOf(todo.id), Todos.madeFrom(meeting, listOf(meeting, todo)).map { it.id })

        val link = Note(url = "https://example.com")
        assertNull(Todos.fromTask("Read it", link))
        assertFalse(link.canBeTodo)
    }

    // Abgleich der Haken

    @Test fun mergeTicksKeepsBothDevicesTicks() {
        val base = "- [ ] a\n- [ ] b\n- [ ] c"
        assertEquals("- [x] a\n- [ ] b\n- [x] c", Todos.mergeTicks(base, "- [x] a\n- [ ] b\n- [ ] c", "- [ ] a\n- [ ] b\n- [x] c"))
        // Die eigene Änderung der neueren Seite gewinnt über die der anderen an derselben Unteraufgabe.
        assertEquals("- [ ] a", Todos.mergeTicks("- [x] a", "- [x] a", "- [ ] a"))
        assertEquals("- [x] a", Todos.mergeTicks("- [ ] a", "- [ ] a", "- [x] a"))
        // Zeilen werden an ihren Wörtern erkannt, auch wenn die neuere Seite umgestellt und ergänzt hat.
        assertEquals(
            "- [ ] new\n- [ ] c\n- [x] a\n- [ ] b",
            Todos.mergeTicks(base, "- [ ] new\n- [ ] c\n- [ ] a\n- [ ] b", "- [x] a\n- [ ] b\n- [ ] c"),
        )
    }

    // Suche und Chat

    @Test fun searchFilterFindsOpenTodosOnly() {
        val open = Note(todoStateRaw = "open")
        val done = Note(todoStateRaw = "done", todoDoneAt = System.currentTimeMillis())
        val plain = Note()
        assertTrue(HomeListLogic.matchesKind(open, ProjectsLogic.Kind.TODO))
        assertFalse(HomeListLogic.matchesKind(done, ProjectsLogic.Kind.TODO))
        assertFalse(HomeListLogic.matchesKind(plain, ProjectsLogic.Kind.TODO))
        assertFalse(HomeListLogic.matchesKind(open, ProjectsLogic.Kind.NOTE))
        assertTrue(HomeListLogic.matchesKind(plain, ProjectsLogic.Kind.NOTE))
    }

    @Test fun chatKnowsATodoAndItsState() {
        val note = Note(title = "Pack", text = "- [x] a\n- [ ] b", todoStateRaw = "open")
        assertEquals("To-do, open, 1 of 2 subtasks done: Pack", Todos.chatLine(note))
        assertTrue(NoteChunks.chunks(listOf(note)).any { it.text.startsWith("To-do, open") })
        assertFalse(NoteChunks.chunks(listOf(Note(text = "x"))).any { it.text.startsWith("To-do") })
    }

    @Test fun bucketShowsOpenTodosFirst() {
        val now = System.currentTimeMillis()
        val done = Note(title = "done", todoStateRaw = "done", todoDoneAt = now, projectIDs = listOf("B"), updatedAt = now)
        val open = Note(title = "open", todoStateRaw = "open", projectIDs = listOf("B"), updatedAt = now - 10)
        val plain = Note(title = "plain", projectIDs = listOf("B"), updatedAt = now - 5)
        val sections = ProjectsLogic.sections(ProjectsLogic.elements("B", listOf(done, open, plain)))
        assertEquals(listOf(ProjectsLogic.Kind.TODO, ProjectsLogic.Kind.NOTE), sections.map { it.first })
        assertEquals(listOf("open", "done"), sections.first().second.map { it.title })
        assertEquals(1, ProjectsLogic.openTodos("B", listOf(done, open, plain)))
    }

    @Test fun exportSaysItIsATodo() {
        assertTrue(Note(title = "Pack", todoStateRaw = "open").exportText.contains("[ ] To-do"))
        assertTrue(Note(title = "Pack", todoStateRaw = "done", todoDoneAt = 1).exportText.contains("[x] To-do, done"))
        assertFalse(Note(title = "Pack").exportText.contains("To-do"))
    }
}

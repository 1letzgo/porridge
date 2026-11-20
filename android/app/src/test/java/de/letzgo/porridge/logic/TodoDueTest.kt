package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.sync.SyncMerge
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale

/** iOS: die Fälle „Due day“ von `TodosTests` — mit fester Zeitzone und Sprache, damit beide Plattformen gleich antworten. */
class TodoDueTest {
    private val berlin = ZoneId.of("Europe/Berlin")
    private val gb = Locale.forLanguageTag("en-GB")

    private fun at(text: String, zone: ZoneId = berlin): Long =
        LocalDateTime.parse(text.replace(" ", "T")).atZone(zone).toInstant().toEpochMilli()

    private fun todo(due: String?, done: Boolean = false) =
        Note(todoStateRaw = if (done) "done" else "open", todoDoneAt = if (done) System.currentTimeMillis() else null, todoDueDay = due)

    @Test fun dueKeyIsTheDayOfTheCalendarWithoutTime() {
        // Spät am Abend ist hier noch dieser Tag, während UTC schon beim nächsten ist.
        assertEquals("2026-11-20", Todos.dueKey(at("2026-11-20 23:30"), berlin))
        // Derselbe gespeicherte Tag beginnt um Mitternacht, wo auch immer das Gerät ist.
        val tokyo = ZoneId.of("Asia/Tokyo")
        assertEquals("2026-11-20", Todos.dueKey(Todos.dueStart("2026-11-20", tokyo)!!, tokyo))
        assertTrue(Todos.isDueKey("2026-01-05"))
        assertFalse(Todos.isDueKey("none"))
        assertFalse(Todos.isDueKey(null))
        assertNull(Todos.dueDay("none"))
    }

    @Test fun dueLabelsRelativeToToday() {
        val now = at("2026-11-20 10:00") // ein Freitag
        fun label(key: String) = Todos.dueLabel(key, now, berlin, gb)
        assertEquals("Today", label("2026-11-20"))
        assertEquals("Tomorrow", label("2026-11-21"))
        assertEquals("Yesterday", label("2026-11-19"))
        assertEquals("Tue", label("2026-11-24"))
        assertEquals("Thu", label("2026-11-26"))
        assertEquals("27 Nov", label("2026-11-27"))
        assertEquals("12 Dec", label("2026-12-12"))
        assertEquals("10 Nov", label("2026-11-10"))
        assertEquals("5 Jan 2027", label("2027-01-05"))
    }

    @Test fun overdueStartsAtMidnightAfterTheDueDay() {
        assertEquals(Todos.DueStatus.TODAY, Todos.dueStatus("2026-11-20", at("2026-11-20 23:59"), berlin))
        assertEquals(Todos.DueStatus.OVERDUE, Todos.dueStatus("2026-11-20", at("2026-11-21 00:00"), berlin))
        assertEquals(Todos.DueStatus.LATER, Todos.dueStatus("2026-11-21", at("2026-11-20 12:00"), berlin))
        assertNull(Todos.dueStatus("none"))
    }

    @Test fun quickChoices() {
        val now = at("2026-11-20 22:00")
        assertEquals("2026-11-20", Todos.dueKey(Todos.DueChoice.TODAY, now, berlin, gb))
        assertEquals("2026-11-21", Todos.dueKey(Todos.DueChoice.TOMORROW, now, berlin, gb))
        // Die Woche beginnt hier am Montag.
        assertEquals("2026-11-23", Todos.dueKey(Todos.DueChoice.NEXT_WEEK, now, berlin, gb))
        // Wo sie am Sonntag beginnt, ist das der Sonntag.
        assertEquals("2026-11-22", Todos.dueKey(Todos.DueChoice.NEXT_WEEK, now, berlin, Locale.US))
    }

    @Test fun openTodosSortByDueUndatedLastDoneAfter() {
        val late = todo("2026-11-01")
        val soon = todo("2026-11-25")
        val none = todo(null)
        val cleared = todo("none")
        val done = todo("2026-10-01", done = true)
        assertEquals(listOf(late, soon, none, cleared, done).map { it.id }, Todos.byDue(listOf(none, done, soon, cleared, late)).map { it.id })
    }

    @Test fun openTodosGroupByDue() {
        val now = at("2026-11-20 10:00")
        val overdue = todo("2026-11-19")
        val today = todo("2026-11-20")
        val later = todo("2027-01-01")
        val none = todo(null)
        val groups = Todos.dueGroups(listOf(none, later, today, overdue), now, berlin)
        assertEquals(listOf("Overdue", "Today", "Upcoming", "No Due Date"), groups.map { it.first })
        assertEquals(listOf(listOf(overdue.id), listOf(today.id), listOf(later.id), listOf(none.id)), groups.map { g -> g.second.map { it.id } })
        assertEquals(listOf("No Due Date"), Todos.dueGroups(listOf(none), now, berlin).map { it.first })
    }

    @Test fun settingAndClearingTheDueDay() {
        var note = todo(null)
        // Was nie gesetzt war, wegzunehmen, schreibt nichts.
        assertNull(Todos.withDue(note, null))
        note = Todos.withDue(note, "2026-12-12")!!
        assertEquals("2026-12-12", note.todoDue)
        note = Todos.withDue(note, null)!!
        assertEquals("none", note.todoDueDay)
        assertNull(note.todoDue)

        // Wieder zur Notiz gemacht behält es den Tag, ohne ihn zu zeigen.
        note = Todos.withDue(note, "2026-12-12")!!
        note = Todos.withTodo(note, false)!!
        assertEquals("2026-12-12", note.todoDueDay)
        assertNull(note.todoDue)
        assertFalse(note.isOverdue)
    }

    @Test fun onlyOpenTodosAreOverdue() {
        assertTrue(todo("2000-01-01").isOverdue)
        assertFalse(todo("2000-01-01", done = true).isOverdue)
        assertFalse(todo("2999-01-01").isOverdue)
    }

    @Test fun dueDaySyncsAndAClearWinsOverOlderRecords() {
        fun record(n: Note) = PorridgeJson.encodeToJsonElement(Note.serializer(), n).jsonObject
        fun decode(r: JsonObject) = PorridgeJson.decodeFromJsonElement(Note.serializer(), r)
        val note = todo("2026-12-12")
        val rec = record(note)
        assertEquals("2026-12-12", rec["todoDueDay"]!!.jsonPrimitive.content)
        assertFalse("a note without a due day writes no field", "todoDueDay" in record(Note()))

        val copy = SyncMerge.adoptNote(decode(rec), rec, Note(id = note.id))
        assertEquals("2026-12-12", copy.todoDue)

        // Eine Version ohne fällige Tage hat die Notiz bearbeitet: kein Feld, der Tag bleibt.
        val old = JsonObject(rec - "todoDueDay" - "todoStateRaw")
        assertEquals("2026-12-12", SyncMerge.adoptNote(decode(old), old, copy).todoDueDay)

        // Anderswo weggenommen.
        val cleared = JsonObject(rec + ("todoDueDay" to JsonPrimitive("none")))
        val after = SyncMerge.adoptNote(decode(cleared), cleared, copy)
        assertNull(after.todoDue)
        assertEquals("none", after.todoDueDay)
    }

    @Test fun chatLineAndExportNameTheDueDay() {
        val note = todo("2026-12-12").copy(title = "Send the offer")
        assertEquals("To-do, open, due 12 December 2026: Send the offer", Todos.chatLine(note, at("2026-11-20 10:00"), berlin))
        assertEquals("To-do, open, due 12 December 2026, overdue: Send the offer", Todos.chatLine(note, at("2026-12-13 10:00"), berlin))
        assertTrue(note.exportText.contains("[ ] To-do, due 12 December 2026"))
        // Die Passage ist auf den fälligen Tag datiert: „was ist diese Woche fällig“ findet sie.
        val chunk = NoteChunks.chunks(listOf(note)).first { it.text.startsWith("To-do") }
        assertEquals("2026-12-12", Todos.dueKey(chunk.date!!))
    }

    @Test fun bucketSortsOpenTodosByDue() {
        val now = System.currentTimeMillis()
        val undated = Note(title = "undated", todoStateRaw = "open", projectIDs = listOf("B"), updatedAt = now)
        val soon = Note(title = "soon", todoStateRaw = "open", todoDueDay = "2999-01-01", projectIDs = listOf("B"), updatedAt = now - 10)
        val late = Note(title = "late", todoStateRaw = "open", todoDueDay = "2000-01-01", projectIDs = listOf("B"), updatedAt = now - 20)
        val todos = ProjectsLogic.ordered(ProjectsLogic.elements("B", listOf(undated, soon, late)), ProjectsLogic.Kind.TODO)
        assertEquals(listOf("late", "soon", "undated"), todos.map { it.title })
    }
}

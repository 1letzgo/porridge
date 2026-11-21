package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** iOS: `testFolderHoldsEveryOpenTodoByDueDayThenThoseDoneToday` (PorridgeTests/TodosTests.swift) — der virtuelle To-do-Ordner. */
class TodoFolderTest {
    private val berlin = ZoneId.of("Europe/Berlin")
    private fun at(y: Int, m: Int, d: Int, h: Int = 0) = LocalDateTime.of(y, m, d, h, 0).atZone(berlin).toInstant().toEpochMilli()

    private fun todo(title: String, due: String? = null, done: Long? = null) =
        Note(title = title, todoStateRaw = if (done == null) "open" else "done", todoDoneAt = done, todoDueDay = due)

    @Test fun folderHoldsEveryOpenTodoByDueDayThenThoseDoneToday() {
        val now = at(2026, 11, 20, 10)
        val late = todo("late", due = "2026-11-19")
        val today = todo("today", due = "2026-11-20")
        val later = todo("later", due = "2026-12-01")
        val undated = todo("undated")
        val filed = todo("filed in a bucket", due = "2026-11-02").copy(projectIDs = listOf("B1"))
        val doneToday = todo("done today", done = now - 3_600_000)
        val doneEarlier = todo("done yesterday", done = now - 24 * 3_600_000)
        val deleted = todo("deleted", due = "2026-11-01").copy(deletedAt = now)
        // Notizen werden nicht archiviert: ein altes `archivedAt` zählt nicht, das To-do ist offen.
        val archived = todo("legacy archived").copy(archivedAt = now)
        val plain = Note(title = "a note")

        val folder = Todos.folder(listOf(undated, later, plain, doneEarlier, today, deleted, late, archived, doneToday, filed), now, berlin)
        assertEquals(listOf("Overdue", "Today", "Upcoming", "No Due Date"), folder.groups.map { it.first })
        assertEquals(listOf(listOf("filed in a bucket", "late"), listOf("today"), listOf("later"), listOf("undated", "legacy archived")), folder.groups.map { g -> g.second.map { it.title } })
        assertEquals(listOf("done today"), folder.doneToday.map { it.title })
        assertEquals(6, folder.open)
        assertEquals(2, folder.overdue)
        assertFalse(folder.isEmpty)

        // Um Mitternacht ist, was heute fällig war, zu spät; das gestern erledigte war schon weg.
        val next = Todos.folder(listOf(late, today, later, doneToday), at(2026, 11, 21), berlin)
        assertEquals(2, next.overdue)
        assertTrue(next.doneToday.isEmpty())
        assertEquals(listOf("Overdue", "Upcoming"), next.groups.map { it.first })

        assertTrue(Todos.folder(listOf(plain, doneEarlier), now, berlin).isEmpty)
    }
}

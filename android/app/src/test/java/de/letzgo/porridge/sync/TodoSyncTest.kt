package de.letzgo.porridge.sync

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.logic.Todos
import de.letzgo.porridge.model.Note
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * iOS: die Sync-Fälle von `TodosTests` — die To-do-Felder stehen nur im Eintrag, wenn sie gesetzt sind; ein Eintrag ohne
 * `todoStateRaw` lässt sie stehen; die Haken beider Geräte werden zusammengeführt.
 */
class TodoSyncTest {
    private fun record(note: Note): JsonObject = PorridgeJson.encodeToJsonElement(Note.serializer(), note).jsonObject

    private fun decode(record: JsonObject): Note = PorridgeJson.decodeFromJsonElement(Note.serializer(), record)

    @Test fun recordsKeepTheTodoAndOlderRecordsDoNotErase() {
        // Eine Notiz, die nie ein To-do war, schreibt keine To-do-Felder: ihr Eintrag und sein Hash bleiben.
        val plain = record(Note(id = "P", text = "hello", createdAt = 1, updatedAt = 2))
        assertTrue(plain.keys.none { it.startsWith("todo") })

        val todo = Note(id = "T", text = "- [x] a", todoStateRaw = "done", todoDoneAt = 1_000_000, todoSourceID = "S", createdAt = 1, updatedAt = 2)
        val rec = record(todo)
        assertEquals("done", rec["todoStateRaw"]!!.jsonPrimitive.content)
        assertEquals(1_000_000L, rec["todoDoneAt"]!!.jsonPrimitive.long)
        assertEquals("S", rec["todoSourceID"]!!.jsonPrimitive.content)

        val copy = SyncMerge.adoptNote(decode(rec), rec, Note(id = "T"))
        assertTrue(copy.isDone)
        assertEquals(1_000_000L, copy.todoDoneAt)
        assertEquals("S", copy.todoSourceID)

        // Eine Version ohne To-dos hat die Notiz bearbeitet: Ihr Eintrag hat keine To-do-Felder, das To-do bleibt hier.
        val old = JsonObject(rec - "todoStateRaw" - "todoDoneAt" - "todoSourceID" + ("text" to JsonPrimitive("- [x] a\nedited elsewhere")))
        val edited = SyncMerge.adoptNote(decode(old), old, copy)
        assertEquals("- [x] a\nedited elsewhere", edited.text)
        assertTrue(edited.isDone)
        assertEquals("S", edited.todoSourceID)

        // Anderswo wieder zur Notiz gemacht.
        val none = JsonObject(rec - "todoDoneAt" + ("todoStateRaw" to JsonPrimitive("none")))
        val back = SyncMerge.adoptNote(decode(none), none, edited)
        assertFalse(back.isTodo)
        assertNull(back.todoDoneAt)
    }

    @Test fun roundTripIsStable() {
        // Ein Eintrag, wie iOS ihn für ein To-do schreibt: gelesen und wieder geschrieben ergibt er denselben Hash.
        val note = Note(id = "T", title = "Pack", text = "- [x] a\n- [ ] b", todoStateRaw = "open", todoSourceID = "S", createdAt = 1, updatedAt = 2)
        val rec = record(note)
        assertEquals(SyncMerge.hash(rec), SyncMerge.hash(record(decode(rec))))
        // Ein älterer Eintrag ohne To-do-Felder bleibt, wie er war.
        val plain = record(Note(id = "P", text = "x", createdAt = 1, updatedAt = 2))
        assertEquals(SyncMerge.hash(plain), SyncMerge.hash(record(decode(plain))))
    }

    private fun todoRecord(text: String, updatedAt: Long, state: String = "open") = JsonObject(
        mapOf("id" to JsonPrimitive("T"), "text" to JsonPrimitive(text), "updatedAt" to JsonPrimitive(updatedAt), "todoStateRaw" to JsonPrimitive(state)),
    )

    @Test fun twoDevicesTickDifferentSubtasks() {
        val base = todoRecord("- [ ] a\n- [ ] b\n- [ ] c", 1)
        val baseState = SyncBase(SyncMerge.hash(base), SyncMerge.hash(base), Todos.baseText(base))
        // Hier wurde „a“ abgehakt, auf dem anderen Gerät, später, „b“.
        val here = todoRecord("- [x] a\n- [ ] b\n- [ ] c", 5)
        val there = todoRecord("- [ ] a\n- [x] b\n- [ ] c", 7)
        val result = SyncMerge.merge(mapOf("T" to SyncMerge.Local(here, 5)), mapOf("T" to there), emptyMap(), mapOf("T" to baseState), now = 10)
        assertEquals("- [x] a\n- [x] b\n- [ ] c", result.merged["T"]!!["text"]!!.jsonPrimitive.content)
        assertEquals("- [x] a\n- [x] b\n- [ ] c", result.toApply["T"]!!["text"]!!.jsonPrimitive.content)
        assertEquals("open", result.merged["T"]!!["todoStateRaw"]!!.jsonPrimitive.content)

        // Die letzte offene auf dem anderen Gerät abgehakt: das zusammengeführte To-do ist erledigt.
        val both = SyncMerge.merge(
            mapOf("T" to SyncMerge.Local(todoRecord("- [x] a\n- [x] b\n- [ ] c", 5), 5)),
            mapOf("T" to todoRecord("- [ ] a\n- [ ] b\n- [x] c", 7)), emptyMap(), mapOf("T" to baseState), now = 10,
        )
        assertEquals("- [x] a\n- [x] b\n- [x] c", both.merged["T"]!!["text"]!!.jsonPrimitive.content)
        assertEquals("done", both.merged["T"]!!["todoStateRaw"]!!.jsonPrimitive.content)
        assertEquals(10L, both.merged["T"]!!["todoDoneAt"]!!.jsonPrimitive.long)
    }

    @Test fun withoutBaseTextTheNewerSideWinsAsBefore() {
        val base = todoRecord("- [ ] a\n- [ ] b", 1)
        val result = SyncMerge.merge(
            mapOf("T" to SyncMerge.Local(todoRecord("- [x] a\n- [ ] b", 5), 5)), mapOf("T" to todoRecord("- [ ] a\n- [x] b", 7)), emptyMap(),
            mapOf("T" to SyncBase(SyncMerge.hash(base), SyncMerge.hash(base))), now = 10,
        )
        assertEquals("- [ ] a\n- [x] b", result.merged["T"]!!["text"]!!.jsonPrimitive.content)
    }

    @Test fun baseTextOnlyForTodoRecords() {
        assertEquals("- [ ] a", Todos.baseText(todoRecord("- [ ] a", 1)))
        assertNull(Todos.baseText(todoRecord("- [ ] a", 1, state = "none")))
        assertNull(Todos.baseText(JsonObject(mapOf("id" to JsonPrimitive("N"), "text" to JsonPrimitive("x")))))
        // Der Stand der Basis ohne Text wird geschrieben wie bisher (keine neue Zeile in state.json).
        assertFalse(PorridgeJson.encodeToString(SyncBase.serializer(), SyncBase("l", "r")).contains("text"))
    }
}

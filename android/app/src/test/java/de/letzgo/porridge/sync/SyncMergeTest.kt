package de.letzgo.porridge.sync

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncMergeTest {
    private fun rec(id: String, text: String, updatedAt: Long) =
        JsonObject(mapOf("id" to JsonPrimitive(id), "text" to JsonPrimitive(text), "updatedAt" to JsonPrimitive(updatedAt)))

    private fun local(r: JsonObject) = SyncMerge.Local(r, SyncMerge.updatedAt(r))

    private fun base(r: JsonObject) = SyncBase(SyncMerge.hash(r), SyncMerge.hash(r))

    @Test fun newOnEitherSideIsKept() {
        val a = rec("A", "here", 1)
        val b = rec("B", "there", 1)
        val result = SyncMerge.merge(mapOf("A" to local(a)), mapOf("B" to b), emptyMap(), emptyMap(), now = 10)
        assertEquals(setOf("A", "B"), result.merged.keys)
        assertEquals(setOf("B"), result.toApply.keys)
    }

    @Test fun theSideThatChangedWins() {
        val old = rec("A", "old", 1)
        val edited = rec("A", "edited", 2)
        // Changed elsewhere only.
        var result = SyncMerge.merge(mapOf("A" to local(old)), mapOf("A" to edited), emptyMap(), mapOf("A" to base(old)), now = 10)
        assertEquals("edited", result.merged.getValue("A")["text"]!!.jsonPrimitive.content)
        assertEquals(setOf("A"), result.toApply.keys)
        // Changed here only, even with an older time stamp.
        val editedHere = rec("A", "here", 0)
        result = SyncMerge.merge(mapOf("A" to local(editedHere)), mapOf("A" to old), emptyMap(), mapOf("A" to base(old)), now = 10)
        assertEquals("here", result.merged.getValue("A")["text"]!!.jsonPrimitive.content)
        assertTrue(result.toApply.isEmpty())
    }

    @Test fun bothChangedTheNewerWins() {
        val old = rec("A", "old", 1)
        val result = SyncMerge.merge(mapOf("A" to local(rec("A", "here", 5))), mapOf("A" to rec("A", "there", 7)), emptyMap(), mapOf("A" to base(old)), now = 10)
        assertEquals("there", result.merged.getValue("A")["text"]!!.jsonPrimitive.content)
    }

    @Test fun deletionsTravelAsTombstones() {
        val a = rec("A", "x", 1)
        // Deleted here: the file gets a tombstone.
        var result = SyncMerge.merge(emptyMap(), mapOf("A" to a), emptyMap(), mapOf("A" to base(a)), now = 10)
        assertTrue("A" !in result.merged)
        assertEquals(10L, result.tombstones["A"])
        // The other device learns it and deletes.
        result = SyncMerge.merge(mapOf("A" to local(a)), emptyMap(), mapOf("A" to 10L), mapOf("A" to base(a)), now = 20)
        assertEquals(setOf("A"), result.toDelete)
        // An edit after the deletion brings it back.
        val edited = rec("A", "again", 15)
        result = SyncMerge.merge(mapOf("A" to local(edited)), emptyMap(), mapOf("A" to 10L), mapOf("A" to base(a)), now = 20)
        assertTrue(result.toDelete.isEmpty())
        assertTrue("A" in result.merged && "A" !in result.tombstones)
    }

    @Test fun frozenRecordsStayAsTheyAre() {
        val result = SyncMerge.merge(mapOf("A" to local(rec("A", "processing", 5))), emptyMap(), emptyMap(), emptyMap(), frozen = setOf("A"), now = 10)
        assertTrue(result.merged.isEmpty() && result.toApply.isEmpty() && result.toDelete.isEmpty())
    }

    /** Two devices with a shared file end up with the same records, whatever each did. */
    @Test fun twoDevicesConverge() {
        class Device { val store = mutableMapOf<String, JsonObject>(); var base = mapOf<String, SyncBase>() }
        var file = mapOf<String, JsonObject>()
        var stones = mapOf<String, Long>()
        var clock = 0L
        fun sync(d: Device) {
            val result = SyncMerge.merge(d.store.mapValues { local(it.value) }, file, stones, d.base, now = ++clock)
            d.store.putAll(result.toApply)
            result.toDelete.forEach { d.store.remove(it) }
            file = result.merged
            stones = result.tombstones
            d.base = result.merged.mapValues { (id, r) -> SyncBase(d.store[id]?.let(SyncMerge::hash) ?: "", SyncMerge.hash(r)) }
        }
        val phone = Device()
        val mac = Device()
        phone.store["1"] = rec("1", "one", 1)
        phone.store["2"] = rec("2", "two", 1)
        sync(phone); sync(mac)
        assertEquals(phone.store, mac.store)
        mac.store["1"] = rec("1", "one from mac", 3)
        phone.store.remove("2")
        phone.store["3"] = rec("3", "three", 4)
        sync(phone); sync(mac); sync(phone)
        assertEquals(phone.store, mac.store)
        assertEquals(setOf("1", "3"), mac.store.keys)
        assertEquals("one from mac", phone.store.getValue("1")["text"]!!.jsonPrimitive.content)
    }

    @Test fun canonicalJsonSortsKeys() {
        val a = JsonObject(mapOf("b" to JsonPrimitive(1), "a" to JsonPrimitive("x")))
        val b = JsonObject(mapOf("a" to JsonPrimitive("x"), "b" to JsonPrimitive(1)))
        assertEquals("""{"a":"x","b":1}""", SyncMerge.canonical(a))
        assertEquals(SyncMerge.hash(a), SyncMerge.hash(b))
    }
}

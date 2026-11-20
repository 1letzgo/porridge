package de.letzgo.porridge.sync

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * iOS: `SyncFixTests` (PorridgeTests/SyncFixTests.swift) — ein gescheiterter Aufnahmeteil und Buckets, die auf einem
 * anderen Gerät gelöscht wurden: wie sie durch die Sync-Datei reisen.
 */
class SyncFixTest {
    private fun decode(record: JsonObject): Note = PorridgeJson.decodeFromJsonElement(Note.serializer(), record)

    @Test fun aFailedPartNoLongerFreezesItsNote() {
        val note = Note(text = "Before", pendingAudioFileName = "Part.m4a", statusRaw = ProcessingStatus.RECORDED.raw)
        assertTrue("a part waiting to be transcribed stays on this device", NextcloudSync.isFrozen(note))
        assertTrue(NextcloudSync.isFrozen(note.copy(statusRaw = ProcessingStatus.TRANSCRIBING.raw)))
        assertFalse(
            "a failed part must not keep its note out of sync for good",
            NextcloudSync.isFrozen(note.copy(statusRaw = ProcessingStatus.FAILED.raw)),
        )
    }

    @Test fun theFailedPartStaysOnThisDevice() {
        val note = Note(
            text = "Before", pendingAudioFileName = "Part.m4a",
            statusRaw = ProcessingStatus.FAILED.raw, errorMessage = "No model",
        )

        val record = NextcloudSync.noteRecord(note)
        assertFalse("the part is not uploaded, so the file does not name it", "pendingAudioFileName" in record)

        // Anderswo bearbeitet: Der Text kommt, der Teil und sein Scheitern bleiben, wie sie hier sind.
        var remote = JsonObject(
            record + ("text" to JsonPrimitive("Edited elsewhere")) + ("statusRaw" to JsonPrimitive(ProcessingStatus.READY.raw)) -
                "errorMessage",
        )
        val edited = SyncMerge.adoptNote(decode(remote), remote, note)
        assertEquals("Edited elsewhere", edited.text)
        assertEquals("Part.m4a", edited.pendingAudioFileName)
        assertEquals(ProcessingStatus.FAILED, edited.status)
        assertEquals("No model", edited.errorMessage)

        // Ein anderes Gerät übernimmt nie einen Teil, den es nicht hat, auch nicht aus einem Eintrag, der einen nennt.
        remote = JsonObject(
            remote + ("pendingAudioFileName" to JsonPrimitive("Elsewhere.m4a")) + ("statusRaw" to JsonPrimitive(ProcessingStatus.FAILED.raw)),
        )
        val fresh = SyncMerge.adoptNote(decode(remote), remote, null)
        assertNull(fresh.pendingAudioFileName)
        assertEquals(ProcessingStatus.FAILED, fresh.status)
        val existing = SyncMerge.adoptNote(decode(remote), remote, Note(id = note.id))
        assertNull(existing.pendingAudioFileName)
        assertEquals(ProcessingStatus.FAILED, existing.status)
    }

    @Test fun theRecordWithoutThePartIsStable() {
        // Gelesen und wieder geschrieben ergibt der Eintrag denselben Hash: Die Notiz gilt danach nicht als geändert.
        val note = Note(text = "Before", pendingAudioFileName = "Part.m4a", statusRaw = ProcessingStatus.FAILED.raw, createdAt = 1, updatedAt = 2)
        val record = NextcloudSync.noteRecord(note)
        val back = SyncMerge.adoptNote(decode(record), record, note)
        assertEquals(note, back)
        assertEquals(SyncMerge.hash(record), SyncMerge.hash(NextcloudSync.noteRecord(back)))
    }

    @Test fun notesLeaveBucketsThatAreGone() {
        val kept = UUID.randomUUID().toString().uppercase()
        val gone = UUID.randomUUID().toString().uppercase()
        val filed = Note(projectIDs = listOf(kept, gone), suggestedProjectIDs = listOf(gone), updatedAt = 5)
        val only = Note(projectIDs = listOf(gone), updatedAt = 7)
        val untouched = Note(projectIDs = listOf(kept.lowercase()), updatedAt = 9)

        val changed = Projects.pruneUnknown(listOf(filed, only, untouched), known = setOf(kept)).associateBy { it.id }

        assertEquals(setOf(filed.id, only.id), changed.keys)
        assertEquals(listOf(kept), changed.getValue(filed.id).projectIDs)
        assertEquals(emptyList<String>(), changed.getValue(filed.id).suggestedProjectIDs)
        assertEquals(emptyList<String>(), changed.getValue(only.id).projectIDs)
        assertTrue("a note whose last bucket is gone is back in the inbox", changed.getValue(only.id).isInInbox)
        assertEquals("leaving a bucket that is gone is no edit", 7L, changed.getValue(only.id).updatedAt)
        assertEquals(listOf(kept.lowercase()), untouched.projectIDs)
    }
}

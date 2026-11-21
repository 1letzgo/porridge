package de.letzgo.porridge.model

import de.letzgo.porridge.data.PorridgeJson
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS: `IntakeModelTests` — die Eingangsfelder einer Notiz im JSON der Sync-Datei. */
class IntakeModelTest {
    @Test fun aNoteWrittenByIosIsReadWithItsIntakeFields() {
        // So schreibt iOS den Eintrag (`SyncRecords.record`): Anhänge als JSON-Text mit sortierten Schlüsseln.
        val json = """{"id":"N1","title":"Shot","text":"","createdAt":1,"updatedAt":2,"statusRaw":"ready","audioFileNames":[],
            "isPinned":false,"labels":[],"projectIDs":[],"titleIsCustom":false,"duration":0,"channelCount":1,"speakerModeRaw":"none",
            "sourceRaw":"share","suggestedProjectIDs":["P1"],"filedAt":5,
            "attachmentsData":"[{\"bytes\":12,\"fileName\":\"A.png\",\"id\":\"X\",\"kindRaw\":\"image\",\"name\":\"Screenshot.png\"}]"}"""
        val note = PorridgeJson.decodeFromString(Note.serializer(), json)
        assertEquals(NoteSource.SHARE, note.source)
        assertEquals(listOf(Attachment("X", "A.png", "Screenshot.png", "image", 12)), note.attachments)
        assertEquals(Attachment.Kind.IMAGE, note.attachments.single().kind)
        assertEquals(listOf("A.png"), note.storedFileNames)
        assertEquals(5L, note.filedAt)
        // In keinem Bucket: im Eingang, auch wenn es einmal abgelegt war.
        assertTrue(note.isInInbox)
        assertTrue(note.isSaved)
        // Zurück in die Datei: derselbe Text der Anhänge, damit der Eintrag als unverändert gilt.
        val record = PorridgeJson.encodeToJsonElement(Note.serializer(), note).jsonObject
        assertEquals(PorridgeJson.parseToJsonElement(json).jsonObject["attachmentsData"], record["attachmentsData"])
        assertTrue("sourceRaw" in record)
    }

    @Test fun aNoteIsInTheInboxUntilItIsInABucket() {
        val note = Note()
        assertTrue(note.isInInbox)
        assertTrue(note.copy(filedAt = 1).isInInbox)
        // Notizen werden nicht archiviert: ein altes `archivedAt` nimmt sie nicht aus dem Eingang.
        assertTrue(note.copy(archivedAt = 1).isInInbox)
        assertFalse(note.copy(projectIDs = listOf("P")).isInInbox)
        assertFalse(note.copy(deletedAt = 1).isInInbox)
        // Auch ein leerer Kanal steht im JSON: Daran erkennt die andere Seite Einträge neuer Versionen.
        assertTrue("sourceRaw" in PorridgeJson.encodeToJsonElement(Note.serializer(), note).jsonObject)
    }

    @Test fun aRecordOfAnOlderVersionKeepsWhatThisDeviceKnows() {
        val local = Note(id = "N", sourceRaw = "share", filedAt = 3, suggestedProjectIDs = listOf("P"))
            .withAttachments(listOf(Attachment("X", "A.pdf", "A.pdf", "pdf")))
        val old = PorridgeJson.decodeFromString(Note.serializer(), """{"id":"N","title":"Renamed elsewhere"}""")
        val kept = old.withIntakeOf(local)
        assertEquals("Renamed elsewhere", kept.title)
        assertEquals(local.attachments, kept.attachments)
        assertEquals(3L, kept.filedAt)
        assertEquals(NoteSource.SHARE, kept.source)
    }
}

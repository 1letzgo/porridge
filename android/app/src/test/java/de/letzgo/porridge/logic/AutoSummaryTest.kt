package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.index.NoteIndex
import de.letzgo.porridge.model.Attachment
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.sync.SyncMerge
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * iOS: `AutoSummaryTests` (PorridgeTests/AutoSummaryTests.swift) — Zusammenfassungen hereingekommener Einträge: welche,
 * wann, auf welchem Gerät, und nie über den Nutzer. Dieselben Fälle.
 */
class AutoSummaryTest {
    private val now = 1_800_000_000_000L
    private val page = "Ein Artikel über Sauerteig, Roggenmehl und lange Gare. ".repeat(8)

    private fun entry(note: Note) = note.copy(createdAt = now - 60_000, updatedAt = now - 60_000)

    private fun link(page: String? = null) =
        entry(Note(url = "https://example.com/sauerteig", sourceRaw = NoteSource.LINK.raw, pageText = page ?: this.page))

    private fun due(note: Note, origin: Boolean = true, enabled: Boolean = true) = AutoSummary.isDue(note, origin, enabled, now)

    private fun share(kindRaw: String, name: String, pageText: String = page) =
        entry(Note(sourceRaw = NoteSource.SHARE.raw, pageText = pageText)).withAttachments(listOf(Attachment(fileName = "a.$kindRaw", name = name, kindRaw = kindRaw)))

    // Welche Einträge

    @Test fun incomingEntriesAreSummarized() {
        assertEquals(AutoSummary.Kind.LINK, AutoSummary.kind(link()))
        assertTrue(due(link()))

        val image = share("image", "IMG.jpg")
        assertEquals(AutoSummary.Kind.IMAGE, AutoSummary.kind(image))
        assertTrue(due(image))

        val file = share("pdf", "Vertrag.pdf")
        assertEquals(AutoSummary.Kind.FILE, AutoSummary.kind(file))
        assertTrue(due(file))

        val shared = entry(Note(sourceRaw = NoteSource.SHARE.raw, text = page))
        assertEquals(AutoSummary.Kind.SHARED_TEXT, AutoSummary.kind(shared))
        assertTrue(due(shared))

        for (source in listOf(NoteSource.AUDIO_IMPORT, NoteSource.PLAUD)) {
            val audio = entry(Note(sourceRaw = source.raw, audioFileName = "a.m4a")).withSegments(listOf(TranscriptSegment(start = 0.0, end = 60.0, text = page)))
            assertEquals(AutoSummary.Kind.IMPORTED_AUDIO, AutoSummary.kind(audio))
            assertTrue(due(audio))
        }
    }

    @Test fun ownNotesToDosAndRecordingsAreNot() {
        val own = entry(Note(text = page))
        assertNull(AutoSummary.kind(own))
        assertFalse(due(own))

        val todo = entry(Note(sourceRaw = NoteSource.SHARE.raw, text = page, todoStateRaw = "open"))
        assertNull("a to-do is the user's own, wherever it came from", AutoSummary.kind(todo))

        val recording = entry(Note(sourceRaw = NoteSource.MEETING.raw, audioFileName = "m.m4a")).withSegments(listOf(TranscriptSegment(start = 0.0, end = 60.0, text = page)))
        assertNull("own meetings are summarized when asked, with a template", AutoSummary.kind(recording))

        val ownWithFile = entry(Note(text = "Mein Text", pageText = page)).withAttachments(listOf(Attachment(fileName = "a.pdf", name = "a.pdf", kindRaw = "pdf")))
        assertNull("a note that got a file attached stays a note", AutoSummary.kind(ownWithFile))
    }

    @Test fun notWhenThereIsLittleOrNoTextYet() {
        assertFalse("too little to summarize", due(link(page = "Kurz.")))
        assertFalse("a page that could not be read", due(link(page = "")))
        assertFalse("the page is still being loaded", due(link().copy(statusRaw = ProcessingStatus.RECORDED.raw)))
        assertFalse("a photo without text", due(share("image", "IMG.jpg", pageText = "")))
        val transcribing = entry(Note(sourceRaw = NoteSource.AUDIO_IMPORT.raw, audioFileName = "a.m4a", statusRaw = ProcessingStatus.TRANSCRIBING.raw))
        assertFalse(due(transcribing))
    }

    @Test fun notWhenOffDeletedOrAlreadySummarized() {
        assertFalse("Summarize Incoming Entries is off", due(link(), enabled = false))
        assertFalse(due(link().copy(deletedAt = now)))
        assertFalse("never twice", due(link().copy(summary = "## Zusammenfassung\nSchon da.")))
        assertFalse("the user is writing one", due(link().copy(summary = "")))
    }

    /** Eine Zusammenfassung, die der Nutzer gelöscht hat, kommt nicht von selbst wieder; ein auf nichts geschlossener Editor hält sie nicht auf. */
    @Test fun aDeletedSummaryStaysDeleted() {
        val note = SummaryLogic.removeSummary(link().copy(summary = "Text", summarizedAt = now), now)
        assertNull(note.summary)
        assertNotNull(note.summarizedAt)
        assertFalse(due(note))

        val never = SummaryLogic.removeSummary(link().copy(summary = ""), now - 60_000)
        assertTrue(due(never))
    }

    // Welches Gerät

    @Test fun theDeviceItCameInOnSummarizesOthersCatchUpLater() {
        val fresh = link()
        assertTrue(due(fresh, origin = true))
        assertFalse("another device leaves it to the device it came in on", due(fresh, origin = false))

        val waiting = link().copy(updatedAt = now - AutoSummary.CATCH_UP_DELAY - 1000)
        assertTrue("no summary after two hours: another device catches up", due(waiting, origin = false))

        val created = now - 40 * 86_400_000L
        val old = link().copy(createdAt = created, updatedAt = created)
        assertFalse("no catching up on everything ever saved", due(old, origin = false))
        assertTrue(due(old, origin = true))
    }

    @Test fun originsAreKeptOnThisDeviceAndPruned() {
        var stored = emptySet<String>()
        val origins = AutoSummary.Origins({ stored }, { stored = it })
        val a = link()
        var b = link()
        val c = link()
        origins.mark(a.id)
        origins.mark(b.id)
        origins.mark(c.id)
        origins.mark(c.id)
        assertTrue(origins.contains(a.id))
        origins.clear(a.id)
        assertFalse(origins.contains(a.id))
        // b bekam seine Zusammenfassung (von einem anderen Gerät), c wartet noch; eine Notiz, die weg ist, fällt auch heraus.
        b = b.copy(summary = "Fertig")
        origins.prune(listOf(b, c))
        assertEquals(setOf(c.id), origins.all())
    }

    /** Ein Eintrag eines anderen Geräts kommt per Sync: Seine Zusammenfassung kommt mit, oder er wird nicht zweimal zusammengefasst. */
    @Test fun syncCarriesTheSummaryAndTheDeletion() {
        fun record(n: Note) = PorridgeJson.encodeToJsonElement(Note.serializer(), n).jsonObject
        fun apply(r: JsonObject, to: Note) = SyncMerge.adoptNote(PorridgeJson.decodeFromJsonElement(Note.serializer(), r), r, to)

        var original = link().copy(summary = "## Zusammenfassung\nSauerteig.", summarizedAt = now)
        var copy = apply(record(original), Note(id = original.id))
        assertFalse(due(copy, origin = false))
        assertFalse(due(copy, origin = true))

        // Auf dem anderen Gerät gelöscht: Der Datensatz hat keine Zusammenfassung, behält aber summarizedAt.
        original = SummaryLogic.removeSummary(original, now)
        val deletedRecord = record(original)
        assertFalse("fields are written only when set", "summary" in deletedRecord)
        copy = apply(deletedRecord, copy).copy(updatedAt = now - AutoSummary.CATCH_UP_DELAY - 1000)
        assertNull(copy.summary)
        assertFalse("a deleted summary does not come back on another device", due(copy, origin = false))

        // Ein Link, der anderswo hereinkam und noch keine Zusammenfassung hat: dem Gerät überlassen, später nachgeholt.
        val fresh = link()
        val pending = apply(record(fresh), Note(id = fresh.id))
        assertFalse(due(pending, origin = false))
    }

    // Versuche

    @Test fun failuresAreRetriedQuietlyAndNotForever() {
        val attempts = AutoSummary.Attempts()
        val id = "X"
        assertTrue(attempts.mayTry(id, now))
        attempts.failed(id, now)
        assertFalse(attempts.mayTry(id, now + 60_000))
        assertTrue(attempts.mayTry(id, now + AutoSummary.RETRY_DELAY))
        attempts.failed(id, now)
        attempts.failed(id, now)
        assertFalse("three times per launch", attempts.mayTry(id, now + 10 * AutoSummary.RETRY_DELAY))
        attempts.succeeded(id)
        assertTrue(attempts.mayTry(id, now))
    }

    // Drumherum

    @Test fun aLinkGetsNoToDoSuggestions() {
        assertNull(TodoSuggestions.offered(link()).todoSuggestionsRaw)
        val summarized = SummaryLogic.carryOver(link().copy(summary = "S", summarizedAt = now), link(), link())
        assertNull(summarized.todoSuggestionsRaw)
    }

    @Test fun theChatIndexTakesTheNewSummary() {
        val note = link()
        val before = NoteIndex.indexHash(note)
        val summarized = note.copy(summary = "## Zusammenfassung\nSauerteig braucht Zeit.")
        assertNotEquals("the index cuts the entry again", before, NoteIndex.indexHash(summarized))
        assertEquals("the chat's entry starts with the summary", "Sauerteig braucht Zeit.", ChatDocument.of(summarized).snippet)
        assertTrue(NoteChunks.chunks(listOf(summarized)).any { it.part == NoteChunk.Part.SUMMARY })
    }
}

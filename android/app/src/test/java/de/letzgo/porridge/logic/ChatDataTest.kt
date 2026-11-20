package de.letzgo.porridge.logic

import de.letzgo.porridge.index.NoteIndex
import de.letzgo.porridge.model.Attachment
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.TranscriptSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * iOS: `ChatDataTests` (PorridgeTests/ChatDataTests.swift) — die Daten des Chats: ein Eintrag je Notiz mit seinen Metadaten
 * (`ChatDocument`), Fragen als Filter gelesen (`ChatQuery`), und der Zusammenhang einer Frage (`ChatLogic.context`). Dieselben
 * Einträge, dieselben Fragen, dieselben Erwartungen.
 */
class ChatDataTest {
    // Freitag, 20. November 2026, Mittag in Berlin; Wochen beginnen am Montag (16. – 22. November).
    private val zone = ZoneId.of("Europe/Berlin")
    private val now = day(20, hour = 12)

    private fun day(day: Int, month: Int = 11, hour: Int = 10): Long =
        LocalDateTime.of(2026, month, day, hour, 0).atZone(zone).toInstant().toEpochMilli()

    private val travel = "B-TRAVEL"
    private val house = "B-HOUSE"
    private val work = "B-WORK"
    private val bucketNames = mapOf(travel to "Reisen", house to "Haus und Garten", work to "Arbeit")

    private class Fixture(val notes: Map<String, Note>) {
        val all: List<Note> get() = notes.values.toList()
        operator fun get(title: String): String = notes.getValue(title).id
    }

    private fun makeFixture(): Fixture {
        val notes = LinkedHashMap<String, Note>()
        fun add(note: Note) { notes[note.title] = note }
        add(Note(title = "Packliste Norwegen", text = "Regenjacke, Wanderschuhe und Fleece einpacken.", createdAt = day(10), projectIDs = listOf(travel)))
        add(
            Note(
                title = "Kickoff Website", createdAt = day(17), projectIDs = listOf(work), audioFileName = "kickoff.m4a",
                summary = "Beschlüsse: Budget 20.000 Euro. Launch im Februar.",
            ).withSpeakers(listOf(Speaker("A", "Anna", 0), Speaker("B", "Ben", 1))).withSegments(listOf(
                TranscriptSegment(speakerId = "A", start = 0.0, end = 5.0, text = "Wir haben beschlossen, das Budget auf 20.000 Euro festzulegen."),
                TranscriptSegment(speakerId = "B", start = 5.0, end = 9.0, text = "Der Launch ist im Februar."),
            )),
        )
        add(
            Note(title = "Weekly", createdAt = day(10), projectIDs = listOf(work), audioFileName = "weekly.m4a")
                .withSegments(listOf(TranscriptSegment(start = 0.0, end = 5.0, text = "Die Entscheidung über das Logo verschieben wir."))),
        )
        add(Note(title = "Swift Concurrency Guide", createdAt = day(18), url = "https://www.swift.org/documentation/concurrency", pageText = "Swift concurrency uses async and await. Actors protect mutable state."))
        add(Note(title = "Sauerteig Rezept", createdAt = day(5), projectIDs = listOf(house), url = "https://example.com/sauerteig", pageText = "Sauerteig braucht Roggenmehl, Wasser und viel Zeit."))
        add(Note(title = "Kotlin Coroutines", createdAt = day(1), projectIDs = listOf(work), url = "https://kotlinlang.org/docs/coroutines-overview.html", pageText = "Coroutines make asynchronous programming in Kotlin simple."))
        add(Note(title = "Angebot an Müller schicken", createdAt = day(1), projectIDs = listOf(work), todoStateRaw = "open", todoDueDay = "2026-11-19"))
        add(Note(title = "Hecke schneiden", text = "- [x] Schere schärfen\n- [ ] Grünschnitt wegbringen", createdAt = day(12), projectIDs = listOf(house), todoStateRaw = "open", todoDueDay = "2026-11-22"))
        add(Note(title = "Steuererklärung", createdAt = day(2), todoStateRaw = "open", todoDueDay = "2026-12-10"))
        add(Note(title = "Fahrrad reparieren", text = "Schlauch hinten tauschen.", createdAt = day(3), projectIDs = listOf(house), todoStateRaw = "open"))
        add(Note(title = "Fährtickets buchen", createdAt = day(4), projectIDs = listOf(travel), todoStateRaw = "done", todoDueDay = "2026-11-18", todoDoneAt = day(18, hour = 9)))
        add(
            Note(title = "Whiteboard", createdAt = day(19), projectIDs = listOf(work), sourceRaw = "share", pageText = "Roadmap Q1: Login, Payments, Export")
                .withAttachments(listOf(Attachment(fileName = "w.jpg", name = "IMG_0042.jpg", kindRaw = "image"))),
        )
        add(
            Note(title = "Mietvertrag", createdAt = day(1, month = 10), projectIDs = listOf(house), sourceRaw = "share", pageText = "Die Kaution beträgt 2.400 Euro und wird auf ein Sparbuch gezahlt.")
                .withAttachments(listOf(Attachment(fileName = "m.pdf", name = "Mietvertrag.pdf", kindRaw = "pdf"))),
        )
        add(Note(title = "Geheimes Projekt", text = "Codename Falke startet im Frühjahr.", createdAt = day(15), deletedAt = day(16)))
        add(Note(title = "Altes Rezept", text = "Pfannkuchen mit Milch, Mehl und Eiern.", createdAt = day(1, month = 3), archivedAt = day(1, month = 4)))
        return Fixture(notes)
    }

    /** Was der Index für die Einträge hält: Einträge und Passagen der lebenden Notizen, wie `NoteIndex.refresh` sie baut. */
    private fun context(question: String, fixture: Fixture, within: Set<String>? = null): ChatContext {
        val living = fixture.all.filter { !it.isDeleted && (within == null || it.id in within) }
        val documents = living.associate { it.id to ChatDocument.of(it) }
        return ChatLogic.context(question, documents, NoteChunks.chunks(living), bucketNames, now, zone)
    }

    private fun listed(context: ChatContext) = context.items.filter { it.isListing }.map { it.noteID }.toSet()
    private fun all(context: ChatContext) = context.items.map { it.noteID }.toSet()
    private fun header(document: ChatDocument) = document.header(bucketNames, now, zone)

    // Der Eintrag

    @Test fun everyKindBecomesAnEntryWithItsMetadata() {
        val f = makeFixture()
        val kinds = f.all.associate { it.title to ChatDocument.of(it).kind }
        assertEquals(ChatDocument.Kind.NOTE, kinds["Packliste Norwegen"])
        assertEquals(ChatDocument.Kind.MEETING, kinds["Kickoff Website"])
        assertEquals(ChatDocument.Kind.LINK, kinds["Swift Concurrency Guide"])
        assertEquals(ChatDocument.Kind.TODO, kinds["Hecke schneiden"])
        assertEquals(ChatDocument.Kind.IMAGE, kinds["Whiteboard"])
        assertEquals(ChatDocument.Kind.FILE, kinds["Mietvertrag"])

        assertEquals(
            "«Hecke schneiden» — To-do, open, due 22 November 2026, 1 of 2 subtasks done · created Thu 12 Nov 2026 · Bucket: Haus und Garten",
            header(ChatDocument.of(f.notes.getValue("Hecke schneiden"))),
        )
        assertTrue(header(ChatDocument.of(f.notes.getValue("Angebot an Müller schicken"))).contains("due 19 November 2026, overdue"))
        assertEquals(
            "«Swift Concurrency Guide» — Link (swift.org) · created Wed 18 Nov 2026 · Inbox · https://www.swift.org/documentation/concurrency",
            header(ChatDocument.of(f.notes.getValue("Swift Concurrency Guide"))),
        )
        assertTrue(header(ChatDocument.of(f.notes.getValue("Altes Rezept"))).contains(" · archived"))
        assertEquals("Beschlüsse: Budget 20.000 Euro. Launch im Februar.", ChatDocument.of(f.notes.getValue("Kickoff Website")).snippet)
        assertEquals("Schlauch hinten tauschen.", ChatDocument.of(f.notes.getValue("Fahrrad reparieren")).snippet)
    }

    @Test fun theEntryChangesWithBucketsArchiveAndState() {
        var note = makeFixture().notes.getValue("Packliste Norwegen")
        val before = NoteIndex.indexHash(note)
        note = note.copy(projectIDs = listOf(house))
        val moved = NoteIndex.indexHash(note)
        assertNotEquals("moving it to another bucket cuts it again", before, moved)
        note = note.copy(archivedAt = now)
        assertNotEquals("archiving it too", moved, NoteIndex.indexHash(note))
        assertTrue(ChatDocument.of(note).archived)
    }

    // Die Frage lesen

    @Test fun aQuestionIsReadAsFilters() {
        fun parse(question: String) = ChatQuery.parse(question, bucketNames, now, zone)
        fun span(from: Int, to: Int) = DaySpan(day(from, hour = 0), day(to, hour = 0))
        val due = parse("Welche To-dos sind diese Woche fällig?")
        assertEquals(setOf(ChatDocument.Kind.TODO), due.kinds)
        assertEquals(ChatQuery.TodoFilter.OPEN, due.todo)
        assertEquals(ChatQuery.DateField.DUE, due.dateField)
        assertEquals(span(16, 23), due.range)
        assertEquals(emptyList<String>(), due.words)

        val meeting = parse("Was haben wir im Meeting am Dienstag beschlossen?")
        assertEquals(setOf(ChatDocument.Kind.MEETING), meeting.kinds)
        assertEquals("the last Tuesday", span(17, 18), meeting.range)
        assertEquals(listOf("beschlossen"), meeting.words)

        val bucket = parse("Was liegt im Bucket Haus und Garten?")
        assertEquals(setOf(house), bucket.bucketIDs)
        assertEquals(emptyList<String>(), bucket.words)

        assertEquals("a due day looks ahead", span(20, 21), parse("Was ist bis Freitag fällig?").range)
        assertEquals(span(23, 30), parse("Was steht nächste Woche an?").range)
        assertEquals(span(17, 18), parse("Notizen vom 17.11.").range)
        assertEquals(span(17, 21), parse("Links der letzten 3 Tage").range)
        assertFalse(parse("Wie hoch ist die Kaution?").isStructured)
        assertEquals(listOf("hoch", "kaution"), parse("Wie hoch ist die Kaution?").words)
    }

    // Fragen und ihr Zusammenhang

    /** 1. Eine Listenfrage nach fälligem Tag: jedes diese Woche fällige To-do, nur offene, sonst nichts aufgezählt. */
    @Test fun toDosDueThisWeek() {
        val f = makeFixture()
        val context = context("Welche To-dos sind diese Woche fällig?", f)
        assertEquals(setOf(f["Angebot an Müller schicken"], f["Hecke schneiden"]), listed(context))
        assertEquals(2, context.matched)
        assertEquals("earliest due first", f["Angebot an Müller schicken"], context.items.first().noteID)
    }

    /** 2. Alles in einem Bucket, welcher Art auch immer. */
    @Test fun everythingInABucket() {
        val f = makeFixture()
        assertEquals(
            setOf(f["Sauerteig Rezept"], f["Hecke schneiden"], f["Fahrrad reparieren"], f["Mietvertrag"]),
            listed(context("Was liegt im Bucket Haus und Garten?", f)),
        )
    }

    /** 3. Ein Meeting nach seinem Wochentag, mit der Passage des Beschlusses. */
    @Test fun theDecisionOfTuesdaysMeeting() {
        val f = makeFixture()
        val context = context("Was haben wir im Meeting am Dienstag beschlossen?", f)
        assertEquals(setOf(f["Kickoff Website"]), listed(context))
        assertTrue(context.items.any { !it.isListing && it.text.contains("Budget auf 20.000 Euro") })
        assertFalse(f["Weekly"] in all(context))
    }

    /** 4. Links zu einem Thema: alle Links aufgezählt, der dazu zuerst, mit seiner Seite. */
    @Test fun linksAboutATopic() {
        val f = makeFixture()
        val context = context("Welche Links habe ich zum Thema Swift gespeichert?", f)
        assertEquals(setOf(f["Swift Concurrency Guide"], f["Sauerteig Rezept"], f["Kotlin Coroutines"]), listed(context))
        assertEquals(f["Swift Concurrency Guide"], context.items.first().noteID)
        assertTrue(context.items.first().text.contains("mentions: swift"))
        assertTrue(context.items.any { !it.isListing && it.noteID == f["Swift Concurrency Guide"] && it.text.contains("Actors") })
    }

    /** 5. Überfällige To-dos. */
    @Test fun overdueToDos() {
        val f = makeFixture()
        assertEquals(setOf(f["Angebot an Müller schicken"]), listed(context("Welche Aufgaben sind überfällig?", f)))
    }

    /** 6. In einer Zeit erledigte To-dos, nach dem Tag, an dem sie erledigt wurden. */
    @Test fun toDosDoneThisWeek() {
        val f = makeFixture()
        assertEquals(setOf(f["Fährtickets buchen"]), listed(context("Welche To-dos habe ich diese Woche erledigt?", f)))
    }

    /** 7. Eine Frage nur nach Inhalt erreicht den aus einer Datei gelesenen Text. */
    @Test fun theTextOfAFile() {
        val f = makeFixture()
        val context = context("Wie hoch ist die Kaution?", f)
        assertNull(context.matched)
        assertEquals(f["Mietvertrag"], context.items.first().noteID)
        assertTrue(context.items.first().header.contains("File · created"))
    }

    /** 8. Ein Bild nach seiner Art und dem Text darin. */
    @Test fun theTextInAnImage() {
        val f = makeFixture()
        val context = context("Was steht auf dem Foto zur Roadmap?", f)
        assertEquals(setOf(f["Whiteboard"]), listed(context))
        assertTrue(context.items.any { !it.isListing && it.text.contains("Payments") })
    }

    /** 9. Ein Tag: was da angelegt wurde, und die To-dos, die da fällig waren. */
    @Test fun whatWasYesterday() {
        val f = makeFixture()
        assertEquals(setOf(f["Whiteboard"], f["Angebot an Müller schicken"]), listed(context("Was war gestern?", f)))
    }

    /** 10. Nur Links in der Inbox. */
    @Test fun linksInTheInbox() {
        val f = makeFixture()
        assertEquals(setOf(f["Swift Concurrency Guide"]), listed(context("Welche Links liegen noch in der Inbox?", f)))
    }

    /** 11. Meetings der letzten Woche, nicht dieser. */
    @Test fun meetingsOfLastWeek() {
        val f = makeFixture()
        assertEquals(setOf(f["Weekly"]), listed(context("Welche Meetings hatten wir letzte Woche?", f)))
    }

    /** 12. Gelöschte Einträge erreichen den Chat nie; archivierte schon, markiert. */
    @Test fun deletedNeverArchivedMarked() {
        val f = makeFixture()
        assertFalse(f["Geheimes Projekt"] in all(context("Was weißt du über Codename Falke?", f)))
        val pancakes = context("Wie mache ich Pfannkuchen?", f)
        assertEquals(f["Altes Rezept"], pancakes.items.first().noteID)
        assertTrue(pancakes.items.first().header.endsWith(" · archived"))
    }

    /** 13. Ein Chat über einen Bucket sieht nur ihn. */
    @Test fun aBucketChat() {
        val f = makeFixture()
        val within = f.all.filter { travel in it.projectIDs }.map { it.id }.toSet()
        val context = context("Was muss ich für Norwegen einpacken?", f, within)
        assertEquals(f["Packliste Norwegen"], context.items.first().noteID)
        assertTrue(within.containsAll(all(context)))
    }

    /** 14. Filter, auf die nichts passt: Das Modell erfährt es und bekommt die nächsten Passagen aller Einträge, als außerhalb markiert. */
    @Test fun nothingMatchesTheFilters() {
        val f = makeFixture()
        val context = context("Welche Meetings gab es gestern zum Budget?", f)
        assertEquals(0, context.matched)
        assertTrue(context.items.all { it.isOutside })
        assertTrue(f["Kickoff Website"] in all(context))
        val user = ChatLogic.user("?", emptyList(), context)
        assertTrue(user, user.contains("No entry matches (kind: meeting; created on Thu 19 Nov 2026)."))
        assertTrue(user.contains("Excerpts from other entries"))
    }

    // Der Prompt

    @Test fun thePromptListsTheMatchesAndNumbersEverything() {
        val f = makeFixture()
        val question = "Welche To-dos sind diese Woche fällig?"
        val context = context(question, f)
        val user = ChatLogic.user(question, emptyList(), context)
        val system = ChatLogic.system(null, now, zone)
        assertTrue(user, user.contains("Matching entries (kind: to-do; to-do state: open; due between Mon 16 Nov 2026 and Sun 22 Nov 2026): all 2 entries."))
        assertTrue(user.contains("[1] «Angebot an Müller schicken» — To-do, open, due 19 November 2026, overdue"))
        assertTrue(user.contains("[2] «Hecke schneiden» — To-do, open, due 22 November 2026"))
        assertTrue(system.contains("only from the entries and excerpts below"))
        assertTrue(system.contains("found nothing"))
        // Die Nummern des Prompts sind die Nummern der Quellen.
        assertEquals(listOf("Hecke schneiden"), ChatLogic.sources("Bis Sonntag [2].", context.items).map { it.title })
        // Ein kleines Modell bekommt zuerst die Liste; es erfährt, wenn sie gekürzt wurde.
        val many = ChatContext(
            items = (0 until 50).map { ChatContextItem("N$it", "T$it", now, "«T$it» — Note", "x".repeat(150), isListing = true) },
            matched = 50, filter = "kind: note",
        )
        assertTrue(ChatLogic.user("?", emptyList(), many, limit = 7000).contains("the first "))
    }
}

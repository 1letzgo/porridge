package de.letzgo.porridge.logic

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.sync.SyncMerge
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** iOS: `TodoSuggestionsTests` (PorridgeTests/TodoSuggestionsTests.swift) — dieselben Fälle mit denselben Antworten. */
class TodoSuggestionsTest {
    private val berlin = ZoneId.of("Europe/Berlin")

    /** Freitag, 20. November 2026, 10:00 in Berlin. */
    private val meetingDate = LocalDateTime.of(2026, 11, 20, 10, 0).atZone(berlin).toInstant().toEpochMilli()

    private val summary = listOf(
        "## Zusammenfassung",
        "Wir haben den Launch geplant.",
        "",
        "## Entscheidungen",
        "- [ ] Not a task here? It is a checkbox, so it counts.",
        "",
        "## Aufgaben",
        "- [ ] Angebot an den Kunden schicken – Daniel – 2026-11-27",
        "- [ ] Raum buchen – Anna – 28.11.",
        "- [x] Protokoll verschicken – Ben",
        "- [ ] **Roadmap** aktualisieren – – nicht genannt",
        "- [ ] Angebot an den Kunden schicken – Daniel",
        "- [ ] Budget prüfen – Anna und Daniel – nächste Woche",
    ).joinToString("\n")

    private fun suggestions(names: List<String> = listOf("daniel")) = TodoSuggestions.parse(summary, meetingDate, berlin, names)

    @Test fun openTasksBecomeSuggestionsOnceEach() {
        assertEquals(
            listOf("Not a task here? It is a checkbox, so it counts.", "Angebot an den Kunden schicken", "Raum buchen", "Roadmap aktualisieren", "Budget prüfen"),
            suggestions().map { it.title },
        )
    }

    @Test fun ownerAndDueDayAreReadNothingIsGuessed() {
        val all = suggestions().associateBy { it.title }
        assertEquals("Daniel", all["Angebot an den Kunden schicken"]?.owner)
        assertEquals("2026-11-27", all["Angebot an den Kunden schicken"]?.dueDay)
        assertEquals("Anna", all["Raum buchen"]?.owner)
        assertEquals("2026-11-28", all["Raum buchen"]?.dueDay)
        // Platzhalter sind keine Zuständigen; „nächste Woche“ ist kein Datum.
        assertNull(all["Roadmap aktualisieren"]?.owner)
        assertNull(all["Roadmap aktualisieren"]?.dueDay)
        assertEquals("Anna und Daniel", all["Budget prüfen"]?.owner)
        assertNull(all["Budget prüfen"]?.dueDay)
    }

    @Test fun mineIsTheUsersAndNobodys() {
        val all = suggestions().associate { it.title to it.isMine }
        assertEquals(true, all["Angebot an den Kunden schicken"])
        assertEquals(false, all["Raum buchen"])
        assertEquals(true, all["Roadmap aktualisieren"])
        assertEquals(true, all["Budget prüfen"])
        assertEquals(listOf("Not a task here? It is a checkbox, so it counts.", "Roadmap aktualisieren"), suggestions(emptyList()).filter { it.isMine }.map { it.title })
    }

    @Test fun dueDaysInTheirWritings() {
        fun due(text: String) = TodoSuggestions.dueDay(text, meetingDate, berlin)
        assertEquals("2026-12-01", due("2026-12-01"))
        assertEquals("2026-12-01", due("1.12.2026"))
        assertEquals("2026-12-01", due("01.12.26"))
        assertEquals("2026-11-28", due("28 November"))
        assertEquals("2026-11-28", due("28. Nov."))
        assertEquals("2026-11-28", due("November 28, 2026"))
        assertEquals("2026-12-04", due("Friday, 4 December 2026"))
        assertEquals("2026-12-03", due("le 3 décembre"))
        // Ein Tag ohne Jahr vor dem Meeting ist der im nächsten Jahr.
        assertEquals("2027-01-15", due("15.1."))
        assertEquals("2027-11-10", due("10 November"))
        // Wörter und unmögliche Tage sind kein Datum.
        assertNull(due("next Friday"))
        assertNull(due("Ende des Monats"))
        assertNull(due("in 2 weeks"))
        assertNull(due("31.2.2026"))
        assertNull(due("Anna"))
    }

    @Test fun theSameTaskAcrossSummaries() {
        assertEquals("send the offer", TodoSuggestions.key("Send the offer!"))
        assertEquals("prufe olstand", TodoSuggestions.key("Prüfe Ölstand"))
        assertTrue(TodoSuggestions.isSame("send the offer to the customer", "send the offer to customer"))
        assertFalse(TodoSuggestions.isSame("send the offer", "send the invoice"))
        assertFalse(TodoSuggestions.isSame("call", "call anna"))
    }

    @Test fun takenAndDismissedStayHandledAfterANewSummary() {
        val states = mapOf(
            TodoSuggestions.key("Angebot an den Kunden schicken") to TodoSuggestions.TAKEN,
            TodoSuggestions.key("Raum buchen") to TodoSuggestions.DISMISSED,
        )
        val rewritten = "## Aufgaben\n- [ ] Angebot an die Kunden schicken – Daniel\n- [ ] Raum buchen – Anna\n- [ ] Neue Aufgabe"
        val pending = TodoSuggestions.pending(TodoSuggestions.parse(rewritten, meetingDate, berlin, emptyList()), states, emptyList())
        assertEquals(listOf("Neue Aufgabe"), pending.map { it.title })
        // Ein anders gemachtes To-do zählt auch als übernommen.
        val other = TodoSuggestions.pending(TodoSuggestions.parse("- [ ] Neue Aufgabe", meetingDate, berlin, emptyList()), emptyMap(), listOf("Neue Aufgabe"))
        assertTrue(other.isEmpty())
    }

    @Test fun statesAreStoredAsSortedJSON() {
        assertEquals("""{"a":"taken","b":"dismissed"}""", TodoSuggestions.encode(mapOf("b" to "dismissed", "a" to "taken")))
        assertEquals(mapOf("a" to "taken"), TodoSuggestions.states("""{"a":"taken"}"""))
        assertEquals(emptyMap<String, String>(), TodoSuggestions.states(null))
        assertEquals(emptyMap<String, String>(), TodoSuggestions.states("not json"))
        assertEquals("{}", TodoSuggestions.encode(emptyMap()))
    }

    private fun meeting(projects: List<String> = emptyList()) =
        TodoSuggestions.offered(Note(title = "Launch", projectIDs = projects, summary = summary, createdAt = meetingDate))

    @Test fun takingMakesTodosInTheBucketAndDismissesTheRest() {
        var meeting = meeting(listOf("B1"))
        val all = TodoSuggestions.pendingFor(meeting, emptyList(), berlin, emptyList())
        assertEquals(5, all.size)
        val chosen = all.filter { it.title.startsWith("Angebot") || it.title.startsWith("Raum") }
        val rest = all.filter { it !in chosen }
        val (made, updated) = TodoSuggestions.take(chosen, rest, meeting, asOne = false)!!
        meeting = updated
        assertEquals(listOf("Angebot an den Kunden schicken", "Raum buchen"), made.map { it.title })
        assertTrue(made.all { it.isTodo && it.projectIDs == listOf("B1") && it.todoSourceID == meeting.id })
        assertEquals(listOf("2026-11-27", "2026-11-28"), made.map { it.todoDueDay })
        // Die Aufgabe eines anderen nennt im To-do, wer zuständig ist.
        assertEquals("Owner: Anna", made[1].text)
        assertTrue(TodoSuggestions.pendingFor(meeting, made, berlin, emptyList()).isEmpty())

        // „Suggest To-dos“ holt die verworfenen zurück, nicht die übernommenen.
        meeting = TodoSuggestions.suggestedAgain(meeting)!!
        assertEquals(3, TodoSuggestions.pendingFor(meeting, made, berlin, emptyList()).size)
    }

    @Test fun takingAsOneTodoWithSubtasks() {
        val meeting = meeting()
        val all = TodoSuggestions.pendingFor(meeting, emptyList(), berlin, emptyList())
        val (made, _) = TodoSuggestions.take(all.take(3), emptyList(), meeting, asOne = true)!!
        assertEquals(1, made.size)
        assertEquals("Follow-ups: Launch", made[0].title)
        assertEquals(3, made[0].todoProgress.total)
        assertEquals("2026-11-27", made[0].todoDueDay)
        assertTrue(made[0].text.contains("- [ ] Raum buchen (Anna)"))
    }

    @Test fun nothingIsOfferedWithoutASummaryOrFromSavedPages() {
        val note = Note()
        assertFalse(TodoSuggestions.offers(note))
        val summarized = note.copy(summary = summary)
        assertFalse("suggestions only after a summary was written or asked for", TodoSuggestions.offers(summarized))
        assertTrue(TodoSuggestions.offers(TodoSuggestions.offered(summarized)))
        val link = TodoSuggestions.offered(Note(url = "https://example.com", summary = summary))
        assertFalse(TodoSuggestions.offers(link))
        assertTrue(TodoSuggestions.pendingFor(link, emptyList(), berlin, emptyList()).isEmpty())
    }

    @Test fun statesSyncAndOlderRecordsKeepThem() {
        fun record(n: Note) = PorridgeJson.encodeToJsonElement(Note.serializer(), n).jsonObject
        fun decode(r: JsonObject) = PorridgeJson.decodeFromJsonElement(Note.serializer(), r)
        val meeting = Note(todoSuggestionsRaw = """{"raum buchen":"dismissed"}""")
        val rec = record(meeting)
        assertEquals("""{"raum buchen":"dismissed"}""", rec["todoSuggestionsRaw"]!!.jsonPrimitive.content)
        assertFalse("todoSuggestionsRaw" in record(Note()))
        val copy = SyncMerge.adoptNote(decode(rec), rec, Note(id = meeting.id))
        assertEquals(meeting.todoSuggestionsRaw, copy.todoSuggestionsRaw)
        val old = JsonObject(rec - "todoSuggestionsRaw")
        assertEquals(meeting.todoSuggestionsRaw, SyncMerge.adoptNote(decode(old), old, copy).todoSuggestionsRaw)
    }

    /** Was ein kleines Modell für ein deutsches Meeting am 20. November schrieb: den Tag des Meetings in jeder Aufgabe, oder die Frist nur in ihren Worten. */
    @Test fun meetingDayCopiedIntoTasksIsDroppedAndTheTasksOwnWordsCount() {
        fun split(text: String) = TodoSuggestions.split(text, meetingDate, berlin)
        assertNull(split("Aktualisiere die Roadmap bis Ende des Monats – Ben – 2026-11-20").third)
        assertEquals("2026-12-03", split("Kläre bis zum 3. Dezember das Budget – Daniel – 2026-11-20").third)
        assertEquals("2026-12-03", split("Kläre das Budget – Daniel – bis zum 3. Dezember").third)
        assertNull(split("Aktualisiere die Roadmap – Ben – Ende des Monats").third)
        assertEquals("Ben", split("Ben aktualisiere die Roadmap – Ben – Ende des Monats").second)
        // Heute fällig, so gesagt: Der Tag des Meetings bleibt.
        assertEquals("2026-11-20", split("Angebot heute an den Kunden schicken – Daniel – 2026-11-20").third)
    }

    @Test fun summaryWrittenOffersItsTasksAndKeepsDecisions() {
        val before = Note(title = "Launch")
        val summarized = before.copy(summary = summary)
        val after = SummaryLogic.carryOver(summarized, before, before)
        assertEquals("{}", after.todoSuggestionsRaw)
        // Was schon entschieden war, bleibt bei einer neuen Zusammenfassung.
        val decided = before.copy(todoSuggestionsRaw = """{"raum buchen":"dismissed"}""")
        assertEquals(decided.todoSuggestionsRaw, SummaryLogic.carryOver(summarized, decided, decided).todoSuggestionsRaw)
        // Nie bei einem Link.
        val link = Note(url = "https://example.com")
        assertNull(SummaryLogic.carryOver(link.copy(summary = "x"), link, link).todoSuggestionsRaw)
    }
}

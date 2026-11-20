package de.letzgo.porridge.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * iOS: `TodoSuggestionsDateGuessTests` (PorridgeTests/TodoSuggestionsDateGuessTests.swift) — dieselben Fälle mit denselben
 * Antworten. Die eigenen Worte einer Aufgabe sind kein Datum, solange sie keins nennen: Kurzformen, die Alltagswörter sind
 * („out“, „set“, „may“), zählen nur mit markiertem Tag oder einem Jahr.
 */
class TodoSuggestionsDateGuessTest {
    private val berlin = ZoneId.of("Europe/Berlin")

    /** Freitag, 20. November 2026, 10:00 in Berlin. */
    private val meetingDate = LocalDateTime.of(2026, 11, 20, 10, 0).atZone(berlin).toInstant().toEpochMilli()

    private fun split(text: String) = TodoSuggestions.split(text, meetingDate, berlin)

    @Test fun everydayWordsInTheTaskAreNoMonth() {
        assertNull(split("Pick 2 out of the 5 offers – Anna").third)
        assertEquals("Anna", split("Pick 2 out of the 5 offers – Anna").second)
        assertNull(split("Prepare 1 set of slides").third)
        assertNull(split("Check whether option 2 may work – Ben").third)
        assertNull(split("Set 2 reminders for the launch").third)
        assertNull(split("Gib 3 mag ich nicht weiter").third)
        assertNull(split("Plan 4 ago meetings").third)
        assertNull(split("Buy 3 mar charts").third)
    }

    @Test fun realDatesInTheTaskStillCount() {
        assertEquals("2026-12-03", split("Kläre bis zum 3. Dezember das Budget").third)
        assertEquals("2026-11-28", split("Send the offer by 28 November").third)
        assertEquals("2026-11-28", split("Send the offer by Nov 28").third)
        assertEquals("2026-11-28", split("Send the offer by 28 Nov").third)
        // Markierte Tage und Jahre machen auch die Alltagswörter zum Monat.
        assertEquals("2027-05-02", split("Angebot bis 2. Mai schicken").third)
        assertEquals("2027-05-04", split("Send the offer by May 4th").third)
        assertEquals("2027-05-04", split("Send the offer by 4th May").third)
        assertEquals("2027-05-04", split("Send the offer by May 4, 2027").third)
        assertEquals("2027-10-02", split("Enviar a proposta até 2 de out de 2027").third)
    }

    @Test fun theDatePartKeepsShortForms() {
        assertEquals("2027-05-04", split("Send the offer – Anna – 4 mai").third)
        assertEquals("2027-10-02", split("Enviar a proposta – Ana – 2 out").third)
        assertEquals("2027-09-01", TodoSuggestions.dueDay("1 set", meetingDate, berlin))
        assertNull(TodoSuggestions.dueDay("1 set", meetingDate, berlin, strict = true))
    }
}

package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/** iOS: `ChatTests` — dieselben Fälle. */
class ChatLogicTest {
    @Test fun everythingANoteHoldsBecomesPassages() {
        val file = Note(
            id = "F", title = "Rechnung", sourceRaw = "share", pageText = "Rechnung 4711 über 129 Euro", summary = "Eine Rechnung über 129 Euro.",
            attachmentsData = """[{"id":"A","fileName":"a.pdf","name":"Rechnung-4711.pdf","kindRaw":"pdf"}]""",
        )
        val link = Note(id = "L", title = "Artikel", url = "https://example.com/a", pageText = "Der Artikel handelt von Hafer.")
        val titleOnly = Note(id = "T", title = "Nur ein Titel")
        val texts = NoteChunks.chunks(listOf(file, link, titleOnly)).map { it.text }
        assertTrue("File: Rechnung-4711.pdf" in texts)
        assertTrue("Text of the file: Rechnung 4711 über 129 Euro" in texts)
        assertTrue("Summary: Eine Rechnung über 129 Euro." in texts)
        assertTrue(texts.any { it.startsWith("Saved link (example.com)") })
        assertTrue("Article (example.com): Der Artikel handelt von Hafer." in texts)
        assertTrue("Nur ein Titel" in texts)
        assertTrue(NoteChunks.chunks(listOf(Note(id = "D", text = "gelöscht", deletedAt = 1))).isEmpty())
    }

    private val notes = listOf(
        Note(id = "U", title = "Urlaub", text = "Die Fähre nach Norwegen fährt am Dienstag.", createdAt = 3, projectIDs = listOf("P1")),
        Note(id = "H", title = "Haushalt", text = "Die Waschmaschine braucht einen neuen Schlauch.", createdAt = 2),
        Note(id = "P", title = "Projekt", text = "Der Vertrag wird im März unterschrieben.", createdAt = 1, projectIDs = listOf("P2")),
    )
    private val chunks = NoteChunks.chunks(notes)

    @Test fun aQuestionFindsThePassageWithItsWords() {
        assertEquals("Urlaub", ChatLogic.search("Wann fährt die Fähre?", chunks).first().title)
        assertEquals("word forms count", "Projekt", ChatLogic.search("Verträge", chunks).first().title)
        assertTrue(ChatLogic.search("Quantencomputer", chunks).isEmpty())
        assertEquals(listOf("Urlaub", "Haushalt", "Projekt"), ChatLogic.recent(chunks).map { it.title })
    }

    private val day = 86_400_000L

    /** Die Frage aus dem Screenshot: Eine lange deutsche Notiz voller Füllwörter belegte alle Plätze, die GitHub-Links der letzten Tage fehlten. */
    @Test fun theLinksOfTheLastDaysAreFoundAmongALongNote() {
        val now = System.currentTimeMillis()
        val filler = (1..40).joinToString("\n") { "Die Tage vor der Messe stelle ich mir vor, dass wir in den letzten Wochen der Planung die Bühne $it aufbauen." }
        val notes = listOf(
            Note(id = "F", title = "Fusion MV", text = filler, createdAt = now - day),
            Note(id = "O", title = "Old repo", url = "https://github.com/old/repo", pageText = "An old project.", createdAt = now - 60 * day),
            Note(id = "S", title = "swift-format", url = "https://github.com/swiftlang/swift-format", pageText = "Formatting for Swift source code.", createdAt = now - day),
            Note(id = "L", title = "ollama", url = "https://github.com/ollama/ollama", pageText = "Run large language models locally.", createdAt = now - 2 * day),
            Note(id = "Z", title = "zed", url = "https://github.com/zed-industries/zed", pageText = "A code editor from the creators of Atom.", createdAt = now - 3 * day),
        )
        val question = "Stelle mir die GitHub Highlights der letzten Tage vor"
        assertEquals(listOf("github"), ChatLogic.queryWords(question))
        val titles = ChatLogic.select(question, NoteChunks.chunks(notes), now).map { it.title }.toSet()
        assertTrue(titles.toString(), titles.containsAll(listOf("swift-format", "ollama", "zed")))
        assertFalse("die letzten Tage zuerst", "Old repo" in titles)
        assertFalse("Fusion MV" in titles)
    }

    @Test fun aQuestionNamesItsTime() {
        val zone = ZoneId.of("Europe/Berlin")
        // Mittwoch, 11. November 2026, Mittag.
        val now = LocalDateTime.of(2026, 11, 11, 12, 0).atZone(zone).toInstant().toEpochMilli()
        fun since(question: String) = ChatLogic.since(question, now, zone)
        fun start(month: Int, day: Int) = LocalDate.of(2026, month, day).atStartOfDay(zone).toInstant().toEpochMilli()
        assertEquals(start(11, 11), since("Was steht heute an?"))
        assertEquals(start(11, 10), since("Was kam gestern?"))
        assertEquals("Wochen beginnen am Montag", start(11, 9), since("Was war diese Woche?"))
        assertEquals(start(11, 2), since("What happened last week?"))
        assertEquals(start(11, 4), since("GitHub der letzten Tage"))
        assertEquals(start(11, 8), since("Notizen der letzten 3 Tage"))
        assertEquals(start(10, 28), since("links from the last two weeks"))
        assertEquals(start(11, 1), since("Was ist neu diesen Monat?"))
        assertNull(since("Wann fährt die Fähre?"))
    }

    @Test fun aTimeWithoutMatchesStillAnswers() {
        val now = LocalDate.now().atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val notes = listOf(
            Note(id = "U", title = "Urlaub", text = "Die Fähre nach Norwegen fährt am Dienstag.", createdAt = now - 90 * day),
            Note(id = "E", title = "Einkauf", text = "Milch und Brot.", createdAt = now - 3_600_000),
        )
        val chunks = NoteChunks.chunks(notes)
        // Diese Woche nichts zur Fähre: Die Fähre wird trotzdem gefunden.
        assertEquals("Urlaub", ChatLogic.select("Was gab es diese Woche zur Fähre?", chunks, now).first().title)
        // Kein Wort zum Suchen: die neuesten Notizen dieser Zeit.
        assertEquals(listOf("Einkauf"), ChatLogic.select("Was war heute?", chunks, now).map { it.title })
        // Nur Wörter, die jeder Text hat: die neuesten Notizen.
        assertEquals("Einkauf", ChatLogic.select("Was ist das?", chunks, now).first().title)
    }

    @Test fun oneNoteTakesAtMostThreePlaces() {
        val long = Note(id = "G", title = "Lang", text = (1..20).joinToString("\n\n" + "x".repeat(680) + "\n") { "Absatz $it über Hafer und noch mehr Hafer." })
        val short = Note(id = "K", title = "Kurz", text = "Hafer.")
        val notes = listOf(long, short)
        val picked = ChatLogic.search("Hafer", NoteChunks.chunks(notes))
        assertTrue(picked.count { it.title == "Lang" } <= ChatLogic.PASSAGES_PER_NOTE)
        assertTrue(picked.any { it.title == "Kurz" })
    }

    @Test fun thePromptNamesToday() {
        val now = 1_800_000_000_000L
        assertTrue(ChatLogic.system(null, now).startsWith("Today is " + java.text.DateFormat.getDateInstance(java.text.DateFormat.FULL).format(java.util.Date(now)) + " ("))
    }

    @Test fun aChatIsAboutAllNotesOrOneBucket() {
        val deleted = Note(id = "D", projectIDs = listOf("P1"), deletedAt = 1)
        assertEquals(listOf("U", "H", "P"), ChatLogic.scope(null, notes + deleted).map { it.id })
        val bucket = ChatLogic.scope("P1", notes + deleted).map { it.id }.toSet()
        assertEquals(setOf("U"), bucket)
        // Was nicht im Bucket liegt, findet der Chat über den Bucket nicht.
        val inside = chunks.filter { it.noteID in bucket }
        assertTrue(ChatLogic.search("Vertrag", inside).isEmpty())
        assertEquals(listOf("Urlaub"), ChatLogic.recent(inside).map { it.title })
    }

    @Test fun thePromptNamesBucketsAndTheAnswerItsSources() {
        // iOS: `testThePromptNamesBucketsAndTheAnswerItsSources`.
        val pair = listOf(
            Note(id = "U", title = "Urlaub", text = "Fähre am Dienstag", createdAt = 2_000_000, projectIDs = listOf("P1")),
            Note(id = "P", title = "Projekt", text = "Vertrag im März", createdAt = 2_000_000 - 60_000),
        )
        val documents = pair.associate { it.id to ChatDocument.of(it) }
        val context = ChatLogic.context("Wann ist was?", documents, NoteChunks.chunks(pair), mapOf("P1" to "Reisen"))
        val user = ChatLogic.user("Wann?", listOf(true to "Hallo"), context)
        assertTrue(user, user.contains("[1] «Urlaub» — Note · created "))
        assertTrue(user.contains(" · Bucket: Reisen"))
        assertTrue(user.contains(" · Inbox"))
        assertTrue(user.contains("User: Hallo"))
        assertTrue(user.endsWith("Question: Wann?"))
        assertTrue(ChatLogic.system("Reisen").contains("\"Reisen\""))

        val items = context.items
        assertEquals(listOf("Urlaub"), ChatLogic.sources("Am Dienstag [1].", items).map { it.title })
        assertEquals(listOf("Projekt", "Urlaub"), ChatLogic.sources("Siehe [2, 1] und [9].", items).map { it.title })
        // Ohne Nummer stehen die besten Passagen ein.
        assertEquals(listOf("Urlaub", "Projekt"), ChatLogic.sources("Keine Angabe.", items).map { it.title })
    }

    @Test fun aChatIsNamedAfterItsFirstQuestion() {
        assertEquals("Wann?", ChatLogic.title("Wann?\nUnd wo?"))
        val long = ChatLogic.title("Was haben wir im letzten Meeting beschlossen und wer kümmert sich darum, bitte ausführlich?")
        assertTrue(long.endsWith("…") && long.length <= 60)
    }
}

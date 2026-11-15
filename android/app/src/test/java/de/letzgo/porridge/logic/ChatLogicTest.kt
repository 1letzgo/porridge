package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

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
    private val all = notes.associateBy { it.id }

    @Test fun aQuestionFindsThePassageWithItsWords() {
        assertEquals("Urlaub", ChatLogic.search("Wann fährt die Fähre?", chunks, all).first().title)
        assertEquals("word forms count", "Projekt", ChatLogic.search("Verträge", chunks, all).first().title)
        assertTrue(ChatLogic.search("Quantencomputer", chunks, all).isEmpty())
        assertEquals(listOf("Urlaub", "Haushalt", "Projekt"), ChatLogic.recent(chunks, all).map { it.title })
    }

    @Test fun aChatIsAboutAllNotesOrOneBucket() {
        val deleted = Note(id = "D", projectIDs = listOf("P1"), deletedAt = 1)
        assertEquals(listOf("U", "H", "P"), ChatLogic.scope(null, notes + deleted).map { it.id })
        val bucket = ChatLogic.scope("P1", notes + deleted).associateBy { it.id }
        assertEquals(setOf("U"), bucket.keys)
        // Was nicht im Bucket liegt, findet der Chat über den Bucket nicht.
        assertTrue(ChatLogic.search("Vertrag", chunks, bucket).isEmpty())
        assertEquals(listOf("Urlaub"), ChatLogic.recent(chunks, bucket).map { it.title })
    }

    @Test fun thePromptNamesBucketsAndTheAnswerItsSources() {
        val passages = ChatLogic.recent(chunks, all)
        val user = ChatLogic.user("Wann?", listOf(true to "Hallo"), passages, mapOf("U" to listOf("Reisen")))
        assertTrue(user.contains("[1] «Urlaub»"))
        assertTrue(user.contains(", Reisen)"))
        assertTrue(user.contains(", Inbox)"))
        assertTrue(user.contains("User: Hallo"))
        assertTrue(user.endsWith("Question: Wann?"))
        assertTrue(ChatLogic.system("Reisen").contains("\"Reisen\""))

        assertEquals(listOf("Urlaub"), ChatLogic.sources("Am Dienstag [1].", passages).map { it.title })
        assertEquals(listOf("Haushalt", "Urlaub"), ChatLogic.sources("Siehe [2, 1] und [9].", passages).map { it.title })
        assertEquals(listOf("Urlaub", "Haushalt", "Projekt"), ChatLogic.sources("Keine Angabe.", passages).map { it.title })
    }

    @Test fun aChatIsNamedAfterItsFirstQuestion() {
        assertEquals("Wann?", ChatLogic.title("Wann?\nUnd wo?"))
        val long = ChatLogic.title("Was haben wir im letzten Meeting beschlossen und wer kümmert sich darum, bitte ausführlich?")
        assertTrue(long.endsWith("…") && long.length <= 60)
    }
}

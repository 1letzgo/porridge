package de.letzgo.porridge.processing

import de.letzgo.porridge.data.LinkFetcher
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class LoadedPageTest {
    private val address = "https://www.example.com/a"

    @Test fun changesMadeWhileLoadingStay() {
        // Während des Ladens in den Papierkorb gelegt, in einen Bucket gelegt und bearbeitet.
        val current = Note(id = "L", url = address, title = "Mein Titel", text = "notiert", projectIDs = listOf("p1"),
            deletedAt = 5, statusRaw = ProcessingStatus.RECORDED.raw, errorMessage = "alt")
        val loaded = withLoadedPage(current, LinkFetcher.Page("Seitentitel", "Text der Seite"), address)
        assertEquals("Text der Seite", loaded.pageText)
        assertEquals("Mein Titel", loaded.title)
        assertEquals("notiert", loaded.text)
        assertEquals(listOf("p1"), loaded.projectIDs)
        assertEquals(5L, loaded.deletedAt)
        assertEquals(ProcessingStatus.READY, loaded.status)
        assertEquals(null, loaded.errorMessage)
    }

    @Test fun aPlaceholderTitleIsReplaced() {
        for (title in listOf("", address, "example.com")) {
            val loaded = withLoadedPage(Note(url = address, title = title), LinkFetcher.Page("Seitentitel", "x"), address)
            assertEquals("Seitentitel", loaded.title)
        }
        val untitled = withLoadedPage(Note(url = address, title = address), LinkFetcher.Page(null, "x"), address)
        assertEquals(address, untitled.title)
    }
}

package de.letzgo.porridge.logic

import de.letzgo.porridge.cloud.AIProvider
import de.letzgo.porridge.cloud.ChatService
import de.letzgo.porridge.cloud.CloudLLM
import de.letzgo.porridge.cloud.SummaryModel
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.ml.LocalModel
import de.letzgo.porridge.model.Note
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * iOS: `ChatModelTests` (PorridgeTests/ChatModelTests.swift) — das eigene Modell des Chats („Chat Model“): welches antwortet,
 * der Rückfall auf den Standard, wie viel Zusammenhang jede Art Modell bekommt, und wie eine gescheiterte Anfrage im Chat
 * klingt. Ohne echte Anfragen und ohne Schlüssel.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ChatModelTest {
    private val qwen = SummaryModel.Local(LocalModel.QWEN35)
    private val other = SummaryModel.Local(LocalModel.QWEN3)
    private val claude = SummaryModel.Cloud(AIProvider.ANTHROPIC, "claude-sonnet-4-5")
    private val gpt = SummaryModel.Cloud(AIProvider.OPEN_AI, "gpt-5")

    private fun resolve(stored: String?, available: List<SummaryModel>, usable: Set<SummaryModel>? = null): SummaryModel =
        SummaryModel.resolveChat(stored, available, { usable?.contains(it) ?: true }, qwen)

    @Test fun theChatUsesItsOwnModelOrTheDefault() {
        val list = listOf(qwen, other, claude, gpt)
        assertEquals("nothing chosen: Same as Default", qwen, resolve(null, list))
        assertEquals(qwen, resolve("", list))
        assertEquals("an external model", claude, resolve(claude.id, list))
        assertEquals("another on-device model", other, resolve(other.id, list))
    }

    @Test fun aModelThatIsGoneFallsBackQuietly() {
        assertEquals("removed from the list", qwen, resolve(claude.id, listOf(qwen, gpt)))
        assertEquals("its key was taken away", qwen, resolve(claude.id, listOf(qwen, claude), usable = setOf(qwen)))
        assertEquals("deleted from the device", qwen, resolve(other.id, listOf(qwen)))
    }

    @Test fun theChoiceIsStoredOnThisDevice() {
        val context = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.content.Context>()
        Prefs.initForTests(context.getSharedPreferences("chat-model-test", android.content.Context.MODE_PRIVATE))
        de.letzgo.porridge.ml.ModelManager.init(context)
        // Keine hinzugefügten Cloud-Modelle (und damit kein Blick in den Schlüsselspeicher).
        Prefs.set(Keys.EXTERNAL_MODELS, "[]")
        val before = Prefs.string(Keys.CHAT_MODEL)
        try {
            SummaryModel.chatChoice = null
            assertNull(Prefs.string(Keys.CHAT_MODEL))
            assertEquals(SummaryModel.current, SummaryModel.chat)
            Prefs.set(Keys.CHAT_MODEL, claude.id)
            assertEquals("cloud:anthropic:claude-sonnet-4-5", Prefs.string(Keys.CHAT_MODEL))
            if (claude !in SummaryModel.available) {
                assertNull("a model not in the list is no choice", SummaryModel.chatChoice)
                assertEquals(SummaryModel.current, SummaryModel.chat)
            }
        } finally {
            Prefs.set(Keys.CHAT_MODEL, before)
        }
    }

    @Test fun onlyCloudModelsSayWhatLeavesTheDevice() {
        assertNull(qwen.sendsHint("question"))
        assertEquals("The question and excerpts of your notes goes to Anthropic.", claude.sendsHint("question and excerpts of your notes"))
        assertEquals("The question goes to your server.", SummaryModel.Cloud(AIProvider.CUSTOM, "llama").sendsHint("question"))
    }

    // Platz

    @Test fun eachKindOfModelGetsItsRoom() {
        assertEquals(ChatBudget.STANDARD, ChatBudget.of(qwen))
        assertEquals(ChatBudget.LARGE, ChatBudget.of(claude))
        assertEquals(100_000, ChatBudget.LARGE.promptLimit)
        assertTrue(ChatBudget.LARGE.fillBudget > ChatBudget.STANDARD.fillBudget)
    }

    @Test fun aCloudModelSeesMoreOfTheNotes() {
        val notes = (1..60).map { index ->
            Note(title = "Hafer $index", text = "Hafer wächst auf Feld $index. " + "Mehr über Hafer und Felder. ".repeat(10))
        }
        val documents = notes.associate { it.id to ChatDocument.of(it) }
        val chunks = NoteChunks.chunks(notes)
        fun context(budget: ChatBudget) = ChatLogic.context("Was weiß ich über Hafer?", documents, chunks, emptyMap(), budget = budget)
        assertEquals(10, context(ChatBudget.STANDARD).items.size)
        assertEquals(30, context(ChatBudget.LARGE).items.size)

        val links = notes.map { it.copy(url = "https://example.com/${it.title}") }.associate { it.id to ChatDocument.of(it) }
        val listing = ChatLogic.context("Welche Links gibt es?", links, chunks, emptyMap(), budget = ChatBudget.LARGE)
        assertEquals("all 60 links are listed for a cloud model", 60, listing.items.count { it.isListing })
    }

    // Fehler

    @Test fun aFailedRequestSaysWhatToDo() {
        assertEquals("Anthropic did not accept the API key. Check it in Settings, under AI.", CloudLLM.error(401, "invalid x-api-key", AIProvider.ANTHROPIC).message)
        assertEquals("OpenAI is busy or your usage limit is reached. Try again later.", CloudLLM.error(429, "rate", AIProvider.OPEN_AI).message)
        assertTrue(CloudLLM.error(503, "x", AIProvider.CUSTOM).message!!.startsWith("Your server has a problem"))
        assertEquals("OpenRouter: model not found", CloudLLM.error(400, "model not found", AIProvider.OPEN_ROUTER).message)

        assertEquals("Could not reach Anthropic. Check the internet connection and try again.", ChatService.message(UnknownHostException(), claude))
        assertEquals("Anthropic took too long to answer. Try again in a moment.", ChatService.message(SocketTimeoutException(), claude))
        assertEquals("Please add your Anthropic API key in Settings.", ChatService.message(SummaryException.missingAPIKey("Anthropic"), claude))
    }
}

package de.letzgo.porridge.cloud

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CloudLLMTest {
    private val server = MockWebServer()

    @Before fun start() {
        server.start()
        CloudLLM.baseOverride = server.url("/v1").toString().removeSuffix("/")
        CloudLLM.client = OkHttpClient()
    }

    @After fun stop() {
        CloudLLM.baseOverride = null
        server.close()
    }

    private fun answer(body: String, code: Int = 200) =
        server.enqueue(MockResponse.Builder().code(code).body(body).build())

    @Test fun openAICompatible() = runTest {
        answer("""{"choices":[{"message":{"content":"Hallo"}}]}""")
        assertEquals("Hallo", CloudLLM.complete(AIProvider.OPEN_ROUTER, "k", "m", "sys", "usr"))
        val request = server.takeRequest()
        assertEquals("/v1/chat/completions", request.url.encodedPath)
        assertEquals("Bearer k", request.headers["Authorization"])
        assertEquals("Porridge", request.headers["X-Title"])
        val body = request.body!!.utf8()
        assertTrue(body.contains("\"role\":\"system\"") && body.contains("\"content\":\"usr\""))
    }

    @Test fun anthropicAndGoogle() = runTest {
        answer("""{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}""")
        assertEquals("AB", CloudLLM.complete(AIProvider.ANTHROPIC, "k", "claude", "s", "u"))
        val a = server.takeRequest()
        assertEquals("/v1/messages", a.url.encodedPath)
        assertEquals("k", a.headers["x-api-key"])
        answer("""{"candidates":[{"content":{"parts":[{"text":"G"}]}}]}""")
        assertEquals("G", CloudLLM.complete(AIProvider.GOOGLE, "k", "gemini-x", "s", "u"))
        assertEquals("/v1/models/gemini-x:generateContent", server.takeRequest().url.encodedPath)
    }

    @Test fun errorMessageFromTheProvider() = runTest {
        answer("""{"error":{"message":"Invalid key"}}""", code = 401)
        val error = runCatching { CloudLLM.complete(AIProvider.OPEN_AI, "k", "m", "s", "u") }.exceptionOrNull()
        assertEquals("OpenAI: Invalid key", error?.message)
    }

    @Test fun modelListFiltersNonChatModels() = runTest {
        answer("""{"data":[{"id":"gpt-a"},{"id":"whisper-1"},{"id":"text-embed"},{"id":"gpt-b"}]}""")
        assertEquals(listOf("gpt-b", "gpt-a"), CloudLLM.models(AIProvider.OPEN_AI, "k"))
    }
}

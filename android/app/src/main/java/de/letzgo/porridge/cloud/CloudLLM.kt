package de.letzgo.porridge.cloud

import de.letzgo.porridge.data.Net
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.logic.SummaryException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** iOS: `CloudLLM` (Services/CloudLLM.swift) — ruft den in den Einstellungen gewählten Anbieter mit dem eigenen Schlüssel. */
object CloudLLM {
    /** Für Tests: eine andere Basisadresse statt der des Anbieters. */
    internal var baseOverride: String? = null
    internal var client: OkHttpClient = Net.client

    private fun base(provider: AIProvider): String =
        baseOverride ?: provider.resolvedBaseURL() ?: throw SummaryException.missingBaseURL

    suspend fun complete(provider: AIProvider, apiKey: String, model: String, system: String, user: String): String = withContext(Dispatchers.IO) {
        val base = base(provider)
        if (model.isEmpty()) throw SummaryException.missingModel
        val request = Request.Builder()
        val body: JsonObject = when (provider.style) {
            AIProvider.Style.OPENAI_COMPATIBLE -> {
                request.url("$base/chat/completions")
                if (apiKey.isNotEmpty()) request.header("Authorization", "Bearer $apiKey")
                if (provider == AIProvider.OPEN_ROUTER) {
                    request.header("HTTP-Referer", "https://letzgo.de/porridge")
                    request.header("X-Title", "Porridge")
                }
                buildJsonObject {
                    put("model", model)
                    put("messages", buildJsonArray {
                        add(buildJsonObject { put("role", "system"); put("content", system) })
                        add(buildJsonObject { put("role", "user"); put("content", user) })
                    })
                }
            }
            AIProvider.Style.ANTHROPIC -> {
                request.url("$base/messages")
                request.header("x-api-key", apiKey)
                request.header("anthropic-version", "2023-06-01")
                buildJsonObject {
                    put("model", model)
                    put("max_tokens", 4096)
                    put("system", system)
                    put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("content", user) }) })
                }
            }
            AIProvider.Style.GOOGLE -> {
                request.url("$base/models/$model:generateContent")
                request.header("x-goog-api-key", apiKey)
                buildJsonObject {
                    put("systemInstruction", buildJsonObject { put("parts", buildJsonArray { add(buildJsonObject { put("text", system) }) }) })
                    put("contents", buildJsonArray {
                        add(buildJsonObject {
                            put("role", "user")
                            put("parts", buildJsonArray { add(buildJsonObject { put("text", user) }) })
                        })
                    })
                }
            }
        }
        request.post(body.toString().toRequestBody("application/json".toMediaType()))
        val json = send(request.build(), provider, timeoutSeconds = 240)
        val text = when (provider.style) {
            AIProvider.Style.OPENAI_COMPATIBLE ->
                (json["choices"] as? JsonArray)?.firstOrNull()?.obj()?.get("message")?.obj()?.get("content")?.str()
            AIProvider.Style.ANTHROPIC ->
                (json["content"] as? JsonArray)?.mapNotNull { it.obj()?.get("text")?.str() }?.joinToString("")
            AIProvider.Style.GOOGLE ->
                (json["candidates"] as? JsonArray)?.firstOrNull()?.obj()?.get("content")?.obj()?.get("parts")
                    ?.let { it as? JsonArray }?.mapNotNull { it.obj()?.get("text")?.str() }?.joinToString("")
        }
        if (text.isNullOrEmpty()) throw SummaryException.emptyResponse
        text
    }

    /** Chat-Modelle, die dieser Schlüssel nutzen kann, wie der Anbieter sie meldet. */
    suspend fun models(provider: AIProvider, apiKey: String): List<String> = withContext(Dispatchers.IO) {
        if (!provider.canListModels) return@withContext emptyList()
        val base = baseOverride ?: provider.resolvedBaseURL() ?: return@withContext emptyList()
        val request = Request.Builder()
        when (provider.style) {
            AIProvider.Style.OPENAI_COMPATIBLE -> request.url("$base/models").header("Authorization", "Bearer $apiKey")
            AIProvider.Style.ANTHROPIC -> request.url("$base/models?limit=100").header("x-api-key", apiKey).header("anthropic-version", "2023-06-01")
            AIProvider.Style.GOOGLE -> request.url("$base/models?pageSize=200").header("x-goog-api-key", apiKey)
        }
        val json = send(request.get().build(), provider, timeoutSeconds = 30)
        when (provider.style) {
            AIProvider.Style.GOOGLE -> (json["models"] as? JsonArray).orEmpty().mapNotNull { it.obj() }
                .filter { m -> (m["supportedGenerationMethods"] as? JsonArray)?.any { it.str() == "generateContent" } == true }
                .mapNotNull { it["name"]?.str()?.replace("models/", "") }
                .filter { it.startsWith("gemini") }
                .sortedDescending()
            AIProvider.Style.ANTHROPIC -> (json["data"] as? JsonArray).orEmpty().mapNotNull { it.obj()?.get("id")?.str() }
            AIProvider.Style.OPENAI_COMPATIBLE -> {
                val skip = listOf("embed", "whisper", "tts", "dall-e", "moderation", "audio", "realtime", "image", "transcribe", "ocr")
                (json["data"] as? JsonArray).orEmpty().mapNotNull { it.obj()?.get("id")?.str() }
                    .filter { id -> skip.none { id.lowercase().contains(it) } }
                    .sortedDescending()
            }
        }
    }

    private fun send(request: Request, provider: AIProvider, timeoutSeconds: Long): JsonObject {
        val call = client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS).callTimeout(timeoutSeconds, TimeUnit.SECONDS).build()
        call.newCall(request).execute().use { response ->
            val text = response.body.string()
            if (!response.isSuccessful) {
                val message = runCatching {
                    PorridgeJson.parseToJsonElement(text).jsonObject["error"]?.obj()?.get("message")?.str()
                }.getOrNull() ?: "HTTP ${response.code}"
                throw SummaryException("${provider.label}: $message")
            }
            return runCatching { PorridgeJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: throw SummaryException.emptyResponse
        }
    }

    private fun JsonElement.obj(): JsonObject? = this as? JsonObject
    private fun JsonElement.str(): String? = (this as? JsonPrimitive)?.contentOrNull
}

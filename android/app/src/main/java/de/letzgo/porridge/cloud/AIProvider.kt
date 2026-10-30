package de.letzgo.porridge.cloud

import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SecureStore

/**
 * iOS: `AIProvider` (Services/AIProvider.swift) — der eine Cloud-Dienst, für den der Nutzer seinen eigenen Schlüssel
 * mitbringt. Schreibt Zusammenfassungen und beantwortet den Chat.
 */
enum class AIProvider(val raw: String, val label: String, val baseURL: String?, val style: Style) {
    OPEN_ROUTER("openRouter", "OpenRouter", "https://openrouter.ai/api/v1", Style.OPENAI_COMPATIBLE),
    OPEN_AI("openAI", "OpenAI", "https://api.openai.com/v1", Style.OPENAI_COMPATIBLE),
    ANTHROPIC("anthropic", "Anthropic", "https://api.anthropic.com/v1", Style.ANTHROPIC),
    GOOGLE("google", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta", Style.GOOGLE),
    MISTRAL("mistral", "Mistral", "https://api.mistral.ai/v1", Style.OPENAI_COMPATIBLE),
    GROQ("groq", "Groq", "https://api.groq.com/openai/v1", Style.OPENAI_COMPATIBLE),
    CUSTOM("custom", "Custom (OpenAI-compatible)", null, Style.OPENAI_COMPATIBLE);

    enum class Style {
        /** `POST {base}/chat/completions` mit Bearer-Schlüssel (OpenAI, OpenRouter, Mistral, Ollama, LM Studio …). */
        OPENAI_COMPATIBLE,
        ANTHROPIC,
        GOOGLE,
    }

    /** Ein lokaler Server (Ollama, LM Studio) braucht oft keinen Schlüssel. */
    val requiresKey: Boolean get() = this != CUSTOM

    /** Ob der Anbieter seine Modelle mit dem Schlüssel auflisten kann (OpenRouter hat zu viele für ein Menü). */
    val canListModels: Boolean get() = this != OPEN_ROUTER && this != CUSTOM

    /** Konto im [SecureStore]; OpenRouter behält seinen ursprünglichen Namen. */
    val keyAccount: String get() = if (this == OPEN_ROUTER) "openrouter-api-key" else "api-key.$raw"

    /** Angezeigt, bis die eigene Modellliste des Anbieters geladen ist. */
    val suggestedModels: List<Pair<String, String>>
        get() = when (this) {
            OPEN_ROUTER -> listOf(
                "anthropic/claude-haiku-5.5" to "Claude Haiku 5.5",
                "google/gemini-3.8-flash" to "Gemini 3.8 Flash",
                "openai/gpt-6-luna" to "GPT-6 Luna",
                "anthropic/claude-sonnet-5.5" to "Claude Sonnet 5.5",
            )
            OPEN_AI -> listOf("gpt-6-luna" to "GPT-6 Luna")
            ANTHROPIC -> listOf("claude-haiku-5-5" to "Claude Haiku 5.5")
            GOOGLE -> listOf("gemini-3.8-flash" to "Gemini 3.8 Flash")
            MISTRAL -> listOf("mistral-small-latest" to "Mistral Small")
            GROQ -> listOf("openai/gpt-oss-120b" to "GPT-OSS 120B")
            CUSTOM -> emptyList()
        }

    /** Gewähltes Modell; jeder Anbieter merkt sich sein eigenes. */
    var model: String
        get() = Prefs.string(Keys.aiModel(raw))?.ifEmpty { null } ?: suggestedModels.firstOrNull()?.first.orEmpty()
        set(value) = Prefs.set(Keys.aiModel(raw), value)

    var apiKey: String
        get() = SecureStore.get(keyAccount).orEmpty()
        set(value) = SecureStore.set(value, keyAccount)

    /** Die API-Adresse ohne Schrägstrich am Ende, oder null, wenn die eigene Adresse fehlt. */
    fun resolvedBaseURL(customBaseURL: String = Companion.customBaseURL): String? {
        val text = (baseURL ?: customBaseURL).trim()
        return text.ifEmpty { null }?.removeSuffix("/")
    }

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: OPEN_ROUTER

        var current: AIProvider
            get() = of(Prefs.string(Keys.PROVIDER))
            set(value) = Prefs.set(Keys.PROVIDER, value.raw)

        var customBaseURL: String
            get() = Prefs.string(Keys.CUSTOM_BASE_URL).orEmpty()
            set(value) = Prefs.set(Keys.CUSTOM_BASE_URL, value)
    }
}

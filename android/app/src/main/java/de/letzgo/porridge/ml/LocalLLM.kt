package de.letzgo.porridge.ml

import android.util.Log
import dev.ffmpegkit.llama.Llama
import dev.ffmpegkit.llama.LlamaConfig
import dev.ffmpegkit.llama.LlamaModel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * iOS: `LocalLLM` (Services/LocalLLM.swift, MLX). Auf Android llama.cpp mit GGUF-Modellen. Implementiert [TextModel]
 * für die Zusammenfassung.
 *
 * Wie auf iOS ist immer nur ein Modell im Speicher: Bevor eines lädt, werden die anderen frei, und zwar erst, wenn
 * ihre laufende Antwort fertig ist ([mutex] hält während einer Antwort). Sperren immer in der Reihenfolge
 * [memory] → [mutex]; [generate] hält nur [mutex], solange es schreibt.
 */
class LocalLLM(val model: LocalModel) : TextModel {
    private val mutex = Mutex()
    @Volatile private var loaded: LlamaModel? = null

    override val displayName: String get() = model.displayName
    override val isInstalled: Boolean get() = ModelManager.isInstalled(model.pack)

    /** Ob das Modell gerade im Speicher ist. */
    val isLoaded: Boolean get() = loaded != null

    override suspend fun ensureReady(progress: (Float) -> Unit) {
        // „Bereit“ allein genügt nicht: Ein anderes Modell oder die Freigabe nach der Pause kann es inzwischen entladen haben.
        ModelManager.ensure(model.pack, progress, isLoaded = { loaded != null }) { load() }
    }

    /** Lädt das Modell, nachdem die anderen frei sind (iOS: `LocalLLM.load`). */
    private suspend fun load() = memory.withLock {
        for (other in others()) other.unload()
        mutex.withLock {
            if (loaded == null) {
                val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
                val started = System.currentTimeMillis()
                loaded = Llama.loadModel(
                    model.pack.file(ModelManager.root, "model.gguf").path,
                    LlamaConfig(contextSize = 8192, threads = threads, gpuLayers = 0, temperature = 0.3f, topP = 0.9f, topK = 40, seed = -1),
                )
                Log.i("Porridge", "llm ${model.raw} loaded in ${System.currentTimeMillis() - started} ms")
            }
        }
    }

    override suspend fun generate(system: String, user: String, maxTokens: Int): String {
        // Zwischen ensureReady und hier kann ein anderes Modell dieses verdrängt haben: dann wieder laden statt scheitern.
        repeat(3) {
            mutex.withLock { loaded?.let { return complete(it, system, user, maxTokens) } }
            load()
            ModelManager.markLoaded(model.pack)
        }
        error("The on-device model is not loaded.")
    }

    /** Läuft unter [mutex]: So lange kann kein anderes Modell dieses verdrängen. */
    private suspend fun complete(llama: LlamaModel, system: String, user: String, maxTokens: Int): String {
        // Das kleine Qwen3 denkt sonst laut nach; eine Zusammenfassung braucht nur die Antwort.
        val prompt = if (model.thinks) "$user /no_think" else user
        val result = if (model.gemmaTurns) {
            Llama.complete(llama, prompt = gemmaPrompt(system, prompt), systemPrompt = "", maxTokens = maxTokens)
        } else {
            Llama.complete(llama, prompt = prompt, systemPrompt = system, maxTokens = maxTokens)
        }
        Log.i("Porridge", "llm ${result.tokensGenerated} tokens, ${"%.1f".format(result.tokensPerSecond)} tok/s")
        val text = withoutThinking(result.text)
        if (text.isEmpty()) error("The on-device model returned no text.")
        return text
    }

    override fun beginUse() = ModelManager.beginLLMUse(model.pack)
    override fun endUse() = ModelManager.endLLMUse(model.pack) { unload(ifIdle = true) }

    /**
     * Gibt den Speicher frei; wartet dafür auf eine laufende Antwort. [ifIdle] (die Freigabe nach der Pause): nur, wenn
     * es auch jetzt, unter der Sperre, niemand nutzt — sonst lädt eine Aufgabe, die gerade begonnen hat, ins Leere.
     */
    suspend fun unload(ifIdle: Boolean = false) = mutex.withLock {
        if (ifIdle && ModelManager.llmUsers(model.pack) > 0) return@withLock
        val llama = loaded ?: return@withLock
        Llama.releaseModel(llama)
        loaded = null
        ModelManager.markUnloaded(model.pack)
    }

    private fun others() = all().filter { it !== this }

    companion object {
        private val instances = HashMap<LocalModel, LocalLLM>()

        /** Nur ein Ladevorgang zur Zeit, damit nie zwei Modelle zugleich in den Speicher kommen (iOS: der Actor). */
        private val memory = Mutex()

        @Synchronized fun of(model: LocalModel) = instances.getOrPut(model) { LocalLLM(model) }

        @Synchronized private fun all(): List<LocalLLM> = instances.values.toList()

        /**
         * llama-android 0.1.1 kennt Gemma 4 nicht (kein `<|turn>` in `llama_chat_apply_template`): ohne Systemtext nimmt
         * es den Text so, wie er ist, und liest die Spezial-Tokens darin. So steht hier, was die Vorlage des Modells baut.
         */
        fun gemmaPrompt(system: String, user: String) =
            "<|turn>system\n${system.trim()}<turn|>\n<|turn>user\n${user.trim()}<turn|>\n<|turn>model\n"

        /** iOS: entfernt einen `<think>…</think>`-Block (bei Gemma `<|channel>…<channel|>`), falls ein Modell doch einen schreibt. */
        fun withoutThinking(text: String): String {
            var result = text
            for ((open, close) in listOf("<think>" to "</think>", "<|channel>" to "<channel|>")) {
                while (true) {
                    val start = result.indexOf(open)
                    if (start < 0) break
                    val end = result.indexOf(close, start)
                    result = if (end >= 0) result.removeRange(start, end + close.length) else result.substring(0, start)
                }
                result = result.replace(close, "")
            }
            return result.trim()
        }
    }
}

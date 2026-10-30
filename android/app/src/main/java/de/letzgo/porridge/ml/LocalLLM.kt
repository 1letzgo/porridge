package de.letzgo.porridge.ml

import android.util.Log
import dev.ffmpegkit.llama.Llama
import dev.ffmpegkit.llama.LlamaConfig
import dev.ffmpegkit.llama.LlamaModel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * iOS: `LocalLLM` (Services/LocalLLM.swift, MLX). Auf Android llama.cpp mit GGUF-Modellen. Implementiert [TextModel]
 * für Zusammenfassung und Chat.
 */
class LocalLLM(val model: LocalModel) : TextModel {
    private val mutex = Mutex()
    private var loaded: LlamaModel? = null

    override val displayName: String get() = model.displayName
    override val isInstalled: Boolean get() = ModelManager.isInstalled(model.pack)

    override suspend fun ensureReady(progress: (Float) -> Unit) {
        ModelManager.ensure(model.pack, progress) {
            mutex.withLock {
                if (loaded == null) {
                    val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
                    loaded = Llama.loadModel(
                        model.pack.file(ModelManager.root, "model.gguf").path,
                        LlamaConfig(contextSize = 8192, threads = threads, gpuLayers = 0, temperature = 0.3f, topP = 0.9f, topK = 40, seed = -1),
                    )
                }
            }
        }
    }

    override suspend fun generate(system: String, user: String, maxTokens: Int): String = mutex.withLock {
        val llama = loaded ?: error("The on-device model is not loaded.")
        // Das kleine Qwen3 denkt sonst laut nach; eine Zusammenfassung braucht nur die Antwort.
        val prompt = if (model.thinks) "$user /no_think" else user
        val result = Llama.complete(llama, system, prompt, maxTokens)
        Log.i("Porridge", "llm ${result.tokensGenerated} tokens, ${"%.1f".format(result.tokensPerSecond)} tok/s")
        val text = withoutThinking(result.text)
        if (text.isEmpty()) error("The on-device model returned no text.")
        text
    }

    override fun beginUse() = ModelManager.beginLLMUse()
    override fun endUse() = ModelManager.endLLMUse { unload() }

    suspend fun unload() = mutex.withLock {
        loaded?.let { Llama.releaseModel(it) }
        loaded = null
        ModelManager.markUnloaded(model.pack)
    }

    companion object {
        private val instances = HashMap<LocalModel, LocalLLM>()

        @Synchronized fun of(model: LocalModel) = instances.getOrPut(model) { LocalLLM(model) }

        /** iOS: entfernt einen `<think>…</think>`-Block, falls ein Modell doch einen schreibt. */
        fun withoutThinking(text: String): String {
            var result = text
            while (true) {
                val start = result.indexOf("<think>")
                if (start < 0) break
                val end = result.indexOf("</think>", start)
                result = if (end >= 0) result.removeRange(start, end + "</think>".length) else result.substring(0, start)
            }
            return result.replace("</think>", "").trim()
        }
    }
}

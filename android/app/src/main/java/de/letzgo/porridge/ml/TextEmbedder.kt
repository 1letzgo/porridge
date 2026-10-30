package de.letzgo.porridge.ml

import dev.ffmpegkit.llama.Llama
import dev.ffmpegkit.llama.LlamaConfig
import dev.ffmpegkit.llama.LlamaModel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * iOS: `TextEmbedder` (NLContextualEmbedding, eingebaut). Auf Android Qwen3-Embedding-0.6B über llama.cpp — nur wenn
 * der Nutzer es geladen hat; sonst sucht die App nur nach Wörtern (wie iOS ohne Modell).
 */
object TextEmbedder : SentenceEmbedder {
    private val mutex = Mutex()
    private var loaded: LlamaModel? = null

    val pack get() = ModelCatalog.embedder

    override suspend fun isAvailable(): Boolean {
        if (!ModelManager.isInstalled(pack)) return false
        return runCatching { ensureLoaded() }.isSuccess
    }

    private suspend fun ensureLoaded() {
        ModelManager.ensure(pack) {
            mutex.withLock {
                if (loaded == null) {
                    loaded = Llama.loadModel(pack.file(ModelManager.root, "model.gguf").path, LlamaConfig(contextSize = 1024, threads = 4, gpuLayers = 0, temperature = 0f, topP = 1f, topK = 1, seed = 0))
                }
            }
        }
    }

    override suspend fun vector(text: String): FloatArray? {
        val input = text.trim().take(1500)
        if (input.isEmpty()) return null
        ensureLoaded()
        val raw = mutex.withLock { loaded?.let { Llama.embed(it, input) } } ?: return null
        val norm = kotlin.math.sqrt(raw.fold(0f) { acc, x -> acc + x * x })
        return if (norm > 0) FloatArray(raw.size) { raw[it] / norm } else null
    }

    suspend fun unload() = mutex.withLock {
        loaded?.let { Llama.releaseModel(it) }
        loaded = null
        ModelManager.markUnloaded(pack)
    }
}

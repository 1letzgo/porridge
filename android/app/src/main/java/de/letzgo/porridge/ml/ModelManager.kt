package de.letzgo.porridge.ml

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** iOS: `ModelManager.State`. */
sealed interface ModelState {
    data object NotInstalled : ModelState
    data object Installed : ModelState
    data class Downloading(val fraction: Float) : ModelState
    data object Loading : ModelState
    data object Ready : ModelState
    data class Failed(val message: String) : ModelState

    val isBusy: Boolean get() = this is Downloading || this == Loading
}

/** iOS: `ModelManager` (Services/ModelManager.swift) — Zustand der Modelle auf dem Gerät für die Oberfläche. */
object ModelManager {
    lateinit var root: File
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val states = HashMap<String, MutableStateFlow<ModelState>>()
    private val locks = HashMap<String, Mutex>()

    fun init(context: Context) {
        root = File(context.filesDir, "Models").apply { mkdirs() }
        (listOf(ModelCatalog.parakeet, ModelCatalog.diarizer, ModelCatalog.embedder) + LocalModel.entries.map { it.pack }).forEach { pack ->
            states[pack.id] = MutableStateFlow(if (pack.isInstalled(root)) ModelState.Installed else ModelState.NotInstalled)
            locks[pack.id] = Mutex()
        }
    }

    fun state(pack: ModelPack): StateFlow<ModelState> = states.getValue(pack.id).asStateFlow()
    fun isInstalled(pack: ModelPack) = pack.isInstalled(root)

    /** Lädt herunter (falls nötig) und lädt mit [load] in den Speicher. */
    suspend fun ensure(pack: ModelPack, progress: (Float) -> Unit = {}, load: suspend () -> Unit) {
        val state = states.getValue(pack.id)
        locks.getValue(pack.id).withLock {
            if (state.value == ModelState.Ready) return
            try {
                if (!pack.isInstalled(root)) {
                    state.value = ModelState.Downloading(0f)
                    ModelDownloader.download(pack, root) { fraction ->
                        state.value = ModelState.Downloading(fraction)
                        progress(fraction)
                    }
                }
                state.value = ModelState.Loading
                progress(1f)
                load()
                state.value = ModelState.Ready
            } catch (e: Throwable) {
                state.value = ModelState.Failed(e.message ?: "The model could not be loaded.")
                throw e
            }
        }
    }

    /** Nur herunterladen (Knopf in den Einstellungen), ohne zu laden. */
    suspend fun download(pack: ModelPack) {
        val state = states.getValue(pack.id)
        locks.getValue(pack.id).withLock {
            if (pack.isInstalled(root)) return
            try {
                state.value = ModelState.Downloading(0f)
                ModelDownloader.download(pack, root) { state.value = ModelState.Downloading(it) }
                state.value = ModelState.Installed
            } catch (e: Throwable) {
                state.value = ModelState.Failed(e.message ?: "The download failed.")
            }
        }
    }

    fun markUnloaded(pack: ModelPack) {
        val state = states.getValue(pack.id)
        if (state.value == ModelState.Ready || state.value == ModelState.Loading) state.value = if (pack.isInstalled(root)) ModelState.Installed else ModelState.NotInstalled
    }

    fun delete(pack: ModelPack, unload: () -> Unit) {
        unload()
        pack.directory(root).deleteRecursively()
        states.getValue(pack.id).value = ModelState.NotInstalled
    }

    // Wie viele Aufgaben (eine Zusammenfassung, eine Chat-Antwort) das LLM gerade nutzen. Es wird nicht freigegeben,
    // solange es jemand nutzt; danach nach einer kurzen Pause (eine Reihe Zusammenfassungen hält es geladen).
    private var llmUsers = 0
    private var idleRelease: Job? = null

    @Synchronized fun beginLLMUse() {
        llmUsers++
        idleRelease?.cancel()
    }

    @Synchronized fun endLLMUse(release: suspend () -> Unit) {
        llmUsers = maxOf(0, llmUsers - 1)
        if (llmUsers > 0) return
        idleRelease?.cancel()
        idleRelease = scope.launch {
            delay(20_000)
            if (llmUsers == 0) release()
        }
    }
}

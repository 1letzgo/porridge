package de.letzgo.porridge.ml

import android.content.Context
import android.os.PowerManager
import de.letzgo.porridge.audio.RecordingService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

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
    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val states = HashMap<String, MutableStateFlow<ModelState>>()
    private val locks = HashMap<String, Mutex>()
    private val fetches = ConcurrentHashMap<String, Job>()

    /** Der Nutzer hat den Download abgebrochen: kein Fehler, die Zeile bietet wieder den Download an. */
    private class DownloadCancelled : IOException("The download was cancelled.")

    fun init(context: Context) {
        appContext = context.applicationContext
        root = File(context.filesDir, "Models").apply { mkdirs() }
        (listOf(ModelCatalog.parakeet, ModelCatalog.diarizer) + LocalModel.entries.map { it.pack }).forEach { pack ->
            states[pack.id] = MutableStateFlow(if (pack.isInstalled(root)) ModelState.Installed else ModelState.NotInstalled)
            locks[pack.id] = Mutex()
        }
    }

    fun state(pack: ModelPack): StateFlow<ModelState> = states.getValue(pack.id).asStateFlow()
    fun isInstalled(pack: ModelPack) = pack.isInstalled(root)

    /**
     * Lädt herunter (falls nötig) und lädt mit [load] in den Speicher. [isLoaded] sagt, ob das Modell wirklich im
     * Speicher ist: „Bereit“ kann veraltet sein, wenn ein anderes Modell es verdrängt hat oder es gerade freigegeben wurde.
     */
    suspend fun ensure(pack: ModelPack, progress: (Float) -> Unit = {}, isLoaded: (() -> Boolean)? = null, load: suspend () -> Unit) {
        val state = states.getValue(pack.id)
        locks.getValue(pack.id).withLock {
            if (state.value == ModelState.Ready && isLoaded?.invoke() != false) return
            try {
                if (!pack.isInstalled(root)) {
                    state.value = ModelState.Downloading(0f)
                    fetch(pack) { fraction ->
                        state.value = ModelState.Downloading(fraction)
                        progress(fraction)
                    }
                }
                state.value = ModelState.Loading
                progress(1f)
                load()
                state.value = ModelState.Ready
            } catch (e: DownloadCancelled) {
                state.value = ModelState.NotInstalled
                throw e
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
                fetch(pack) { state.value = ModelState.Downloading(it) }
                state.value = ModelState.Installed
            } catch (e: DownloadCancelled) {
                state.value = ModelState.NotInstalled
            } catch (e: Throwable) {
                state.value = ModelState.Failed(e.message ?: "The download failed.")
            }
        }
    }

    /** Startet [download] unabhängig vom Bildschirm, der den Knopf zeigt: er läuft weiter, wenn man ihn verlässt. */
    fun startDownload(pack: ModelPack) {
        scope.launch { download(pack) }
    }

    /** Bricht einen laufenden Download ab; das bisher Geladene wird gelöscht. Ist er schon fertig, bleibt das Modell. */
    fun cancelDownload(pack: ModelPack) {
        fetches[pack.id]?.cancel()
    }

    /**
     * Lädt herunter, während der Vordergrunddienst (mit Fortschritt in der Benachrichtigung) und ein Wake Lock die App
     * im Hintergrund und bei ausgeschaltetem Bildschirm am Leben halten. iOS: Hintergrund-`URLSession`.
     */
    private suspend fun fetch(pack: ModelPack, onProgress: (Float) -> Unit) {
        val wake = (appContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "porridge:download").apply { acquire(3 * 60 * 60 * 1000L) }
        RecordingService.downloads[pack.displayName] = 0f
        RecordingService.update(appContext)
        var percent = 0
        // Ein eigener Job: Abbrechen trifft nur den Download, nicht die Aufgabe, die auf ihn wartet.
        val job = scope.async {
            ModelDownloader.download(pack, root) { fraction ->
                onProgress(fraction)
                RecordingService.downloads[pack.displayName] = fraction
                // Die Benachrichtigung nur bei jedem neuen Prozent erneuern.
                val now = (fraction * 100).toInt()
                if (now != percent) {
                    percent = now
                    RecordingService.update(appContext)
                }
            }
        }
        fetches[pack.id] = job
        try {
            job.await()
        } catch (e: CancellationException) {
            job.cancel()
            if (!currentCoroutineContext().isActive) throw e
            // Erst wenn der Download wirklich steht, schreibt niemand mehr in den Ordner.
            job.join()
            pack.directory(root).deleteRecursively()
            throw DownloadCancelled()
        } finally {
            fetches.remove(pack.id)
            RecordingService.downloads.remove(pack.displayName)
            RecordingService.update(appContext)
            if (wake.isHeld) wake.release()
        }
    }

    /** Ein Modell kam außerhalb von [ensure] in den Speicher (iOS: `ModelManager.llmDidLoad`). */
    fun markLoaded(pack: ModelPack) {
        val state = states.getValue(pack.id)
        if (state.value == ModelState.Installed) state.value = ModelState.Ready
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

    // Wie viele Aufgaben (Zusammenfassungen, Chat) jedes LLM gerade nutzen, je Modell: Chat und Zusammenfassungen können
    // verschiedene Modelle nutzen. Eines wird nicht freigegeben, solange es jemand nutzt; danach nach einer kurzen Pause
    // (eine Reihe Zusammenfassungen hält es geladen).
    private val llmUseCounts = HashMap<String, Int>()
    private val idleReleases = HashMap<String, Job>()
    private val pendingReleases = HashMap<String, suspend () -> Unit>()

    @Synchronized fun beginLLMUse(pack: ModelPack) {
        llmUseCounts[pack.id] = (llmUseCounts[pack.id] ?: 0) + 1
        idleReleases.remove(pack.id)?.cancel()
    }

    /** Danach bleibt das Modell eine Weile geladen, damit die nächste Zusammenfassung sofort startet (iOS: 2 Minuten). */
    @Synchronized fun endLLMUse(pack: ModelPack, release: suspend () -> Unit) {
        val users = maxOf(0, (llmUseCounts[pack.id] ?: 0) - 1)
        llmUseCounts[pack.id] = users
        if (users > 0) return
        pendingReleases[pack.id] = release
        idleReleases.remove(pack.id)?.cancel()
        idleReleases[pack.id] = scope.launch {
            delay(120_000)
            if (llmUsers(pack) == 0) release()
        }
    }

    /** Ob gerade jemand das Modell nutzt; [LocalLLM.unload] fragt das unter seiner Sperre noch einmal. */
    @Synchronized fun llmUsers(pack: ModelPack): Int = llmUseCounts[pack.id] ?: 0

    /** App im Hintergrund oder Speicher knapp: Ungenutzte Modelle werden sofort frei, sonst endet Android die App zuerst. */
    @Synchronized fun releaseIdleLLM() {
        for (id in pendingReleases.keys.toList()) {
            if ((llmUseCounts[id] ?: 0) > 0) continue
            val release = pendingReleases.remove(id) ?: continue
            idleReleases.remove(id)?.cancel()
            idleReleases[id] = scope.launch { release() }
        }
    }
}

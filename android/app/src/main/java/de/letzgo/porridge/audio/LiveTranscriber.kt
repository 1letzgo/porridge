package de.letzgo.porridge.audio

import de.letzgo.porridge.ml.ModelState
import de.letzgo.porridge.ml.SpeechModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * iOS: `LiveTranscriber` — zeigt beim Aufnehmen, was gesagt wird. Parakeet erkennt das laufende Stück etwa jede
 * Sekunde neu ([RollingRecognizer]); das endgültige Transkript kommt danach aus der Verarbeitung.
 */
class LiveTranscriber {
    sealed interface Phase {
        data object Idle : Phase
        data object Preparing : Phase
        data class Downloading(val fraction: Float) : Phase
        data object Running : Phase
        data class Unavailable(val message: String) : Phase
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()
    private val _confirmed = MutableStateFlow("")
    val confirmed: StateFlow<String> = _confirmed.asStateFlow()
    private val _volatile = MutableStateFlow("")
    val volatile: StateFlow<String> = _volatile.asStateFlow()

    val text: String get() = listOf(_confirmed.value, _volatile.value).filter { it.isNotEmpty() }.joinToString(" ")

    private var rolling: RollingRecognizer? = null

    /** Für den Recorder: bekommt 16-kHz-Mono-Samples. */
    val feed: (FloatArray) -> Unit = { rolling?.append(it) }

    suspend fun start(language: String?) {
        if (_phase.value != Phase.Idle) return
        _phase.value = if (SpeechModel.pack.isInstalled(de.letzgo.porridge.ml.ModelManager.root)) Phase.Preparing else Phase.Downloading(0f)
        try {
            SpeechModel.ensure { fraction -> if (_phase.value is Phase.Downloading) _phase.value = Phase.Downloading(fraction) }
            val rolling = RollingRecognizer(SpeechModel, language) { confirmed, volatile ->
                _confirmed.value = confirmed
                _volatile.value = volatile
            }
            this.rolling = rolling
            rolling.start()
            _phase.value = Phase.Running
        } catch (e: Throwable) {
            _phase.value = Phase.Unavailable(e.message ?: "Live transcript unavailable.")
        }
    }

    /** Kein Live-Erkennen, solange die App im Hintergrund ist (niemand sieht es). */
    fun setPaused(paused: Boolean) {
        rolling?.paused = paused
    }

    /** Hält an und liefert den letzten Live-Text. */
    suspend fun finish(): String {
        val rolling = rolling ?: return text
        val final = rolling.finish()
        if (final.isNotEmpty()) { _confirmed.value = final; _volatile.value = "" }
        this.rolling = null
        return text
    }

    fun cancel() {
        rolling?.cancel()
        rolling = null
    }

    companion object {
        fun phaseFor(state: ModelState): Phase? = (state as? ModelState.Downloading)?.let { Phase.Downloading(it.fraction) }
    }
}

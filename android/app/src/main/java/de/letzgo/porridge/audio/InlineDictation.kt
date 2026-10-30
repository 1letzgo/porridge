package de.letzgo.porridge.audio

import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.ml.SpeechModel
import de.letzgo.porridge.store.AudioStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * iOS: `InlineDictation` — Diktat direkt in einen Text: beim Aufnehmen kommt das Live-Transkript (der Aufrufer zeigt es
 * an Ort und Stelle); nach dem Stoppen wird die ganze Aufnahme noch einmal erkannt, und dieser genauere Text ersetzt
 * den Live-Text.
 */
class InlineDictation {
    enum class Phase { IDLE, RECORDING, POLISHING }

    data class Result(val fileName: String?, val text: String)

    private val _phase = MutableStateFlow(Phase.IDLE)
    val phase: StateFlow<Phase> = _phase.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    /** Live-Text zum Anzeigen, solange aufgenommen wird. */
    val live: StateFlow<String>? get() = RecordingSession.live?.confirmed

    fun start(title: String) {
        if (_phase.value != Phase.IDLE) return
        _error.value = null
        try {
            RecordingSession.start(title.ifEmpty { "Note" })
            _phase.value = Phase.RECORDING
        } catch (e: Throwable) {
            _error.value = e.message
        }
    }

    fun dismissError() { _error.value = null }

    /** Stoppt und liefert den endgültigen Text der ganzen Aufnahme. */
    suspend fun stop(): Result? {
        if (_phase.value != Phase.RECORDING) return null
        _phase.value = Phase.POLISHING
        val (recording, liveText) = RecordingSession.stop()
        var text = liveText
        val fileName = recording?.fileName
        if (fileName != null) {
            runCatching {
                val prepared = withContext(Dispatchers.IO) { AudioPreprocessor.prepare(AudioStore.file(fileName), false) }
                SpeechModel.transcribe(prepared.pcm, Prefs.language).joinToString(" ") { it.text }.trim()
            }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { text = it }
        }
        _phase.value = Phase.IDLE
        return Result(fileName, text)
    }

    fun cancel() {
        if (_phase.value != Phase.RECORDING) return
        RecordingSession.cancel()
        _phase.value = Phase.IDLE
    }
}

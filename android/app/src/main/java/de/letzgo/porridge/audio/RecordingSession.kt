package de.letzgo.porridge.audio

import android.content.Context
import de.letzgo.porridge.data.Prefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Die eine laufende Aufnahme der App (iOS: der Zustand in `RecordingView`/`InlineDictation` plus `LiveRecording`):
 * Recorder und Live-Transkript, erreichbar für Oberfläche und Vordergrunddienst.
 */
object RecordingSession {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var appContext: Context

    var recorder: AudioRecorder? = null
        private set
    var live: LiveTranscriber? = null
        private set
    var title = ""
        private set
    var startedAt = 0L
        private set
    val isRecording: Boolean get() = recorder?.isRecording?.value == true

    /** Der Stopp-Knopf der Benachrichtigung wurde gedrückt; der Bildschirm reagiert darauf. */
    private val _stopRequests = MutableStateFlow(0)
    val stopRequests: StateFlow<Int> = _stopRequests.asStateFlow()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Startet eine Aufnahme mit Live-Transkript. */
    fun start(title: String, withLive: Boolean = true): AudioRecorder {
        check(!isRecording) { "Already recording." }
        val rec = AudioRecorder(appContext)
        val transcriber = if (withLive) LiveTranscriber() else null
        rec.onMono16k = transcriber?.feed
        rec.start()
        recorder = rec
        live = transcriber
        this.title = title
        startedAt = System.currentTimeMillis()
        RecordingService.update(appContext)
        transcriber?.let { scope.launch { it.start(Prefs.language.takeIf { l -> l != "auto" }) } }
        return rec
    }

    /** Hält an; liefert die Aufnahme und den Live-Text. */
    suspend fun stop(): Pair<RecordingResult?, String> {
        val result = recorder?.stop()
        val text = live?.finish().orEmpty()
        recorder = null
        live = null
        RecordingService.update(appContext)
        return result to text
    }

    fun cancel() {
        recorder?.cancel()
        live?.cancel()
        recorder = null
        live = null
        RecordingService.update(appContext)
    }

    fun requestStop() {
        _stopRequests.value += 1
    }

    fun setBusy(busy: Boolean) {
        RecordingService.busy = busy
        if (::appContext.isInitialized) RecordingService.update(appContext)
    }
}

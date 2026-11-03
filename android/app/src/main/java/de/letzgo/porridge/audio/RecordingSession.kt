package de.letzgo.porridge.audio

import de.letzgo.porridge.model.RecordingNote
import androidx.compose.runtime.mutableStateListOf
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.logic.SpeakerAssigner
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Die eine laufende Aufnahme der App (iOS: der Zustand in `RecordingView`/`InlineDictation` plus `LiveRecording`):
 * Recorder und Live-Transkript, erreichbar für Oberfläche und Vordergrunddienst.
 */
object RecordingSession {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var appContext: Context

    // Zustand für Compose: Der Bildschirm wird gezeichnet, bevor die Aufnahme läuft, und muss das danach mitbekommen.
    var recorder: AudioRecorder? by mutableStateOf(null)
        private set
    var live: LiveTranscriber? by mutableStateOf(null)
        private set
    var title = ""
        private set
    var startedAt = 0L
        private set
    val isRecording: Boolean get() = recorder?.isRecording?.value == true
    /** Was während der laufenden Aufnahme notiert wurde (iOS: `RecordingView.notes`). Liegt hier, weil die Aufnahme den Bildschirm überlebt. */
    val notes = mutableStateListOf<RecordingNote>()

    /**
     * Beendet die Aufnahme, wenn ein Bildschirm sie gerade zeigt. Ein direkter Aufruf statt eines Zustands, denn Compose
     * setzt im Hintergrund aus: Sonst wirkte der Stopp-Knopf erst, wenn die App wieder sichtbar ist.
     */
    var stopHandler: (() -> Unit)? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Startet eine Aufnahme mit Live-Transkript. */
    fun start(title: String, withLive: Boolean = true): AudioRecorder {
        check(!isRecording) { "Already recording." }
        notes.clear()
        val rec = AudioRecorder(appContext)
        rec.onInterrupted = ::requestStop
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
        // Das Schließen der Datei kann dauern und gehört nicht auf den Main-Thread.
        val result = withContext(Dispatchers.IO) { recorder?.stop() }
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

    /** Stopp-Knopf der Benachrichtigung oder weggefallenes Mikrofon. Ohne Bildschirm wird die Aufnahme hier zur Notiz. */
    fun requestStop() {
        val handler = stopHandler
        if (handler != null) {
            handler()
        } else {
            scope.launch {
                val (result, text) = stop()
                if (result != null) saveMeeting(result, listOf("Speaker 1", "Speaker 2"), text)
            }
        }
    }

    /** Ein aufgenommenes Meeting wird eine Notiz, die mit Sprechern transkribiert wird. */
    suspend fun saveMeeting(result: RecordingResult, names: List<String>, liveText: String, title: String? = null, projectID: String? = null): Note {
        var note = Note(
            title = title ?: Note.defaultMeetingTitle(System.currentTimeMillis()), titleIsCustom = title != null,
            statusRaw = ProcessingStatus.RECORDED.raw, audioFileName = result.fileName, duration = result.duration,
            channelCount = result.channelCount, inputName = result.inputName,
        )
        if (result.isSplitStereo) {
            note = note.copy(speakerModeRaw = SpeakerMode.CHANNELS.raw).withSpeakers(
                listOf(Speaker(SpeakerAssigner.LEFT_CHANNEL_ID, names[0], 0), Speaker(SpeakerAssigner.RIGHT_CHANNEL_ID, names[1], 1)),
            )
        }
        // Bis das Transkript mit Sprechern fertig ist, steht der Live-Text da.
        if (liveText.isNotEmpty()) note = note.withSegments(listOf(TranscriptSegment(start = 0.0, end = result.duration, text = liveText)))
        if (projectID != null) note = note.copy(projectIDs = listOf(projectID))
        note = note.copy(text = RecordingNote.markdown(notes))
        notes.clear()
        PorridgeDatabase.shared.notes().upsert(note)
        ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
        return note
    }

    fun setBusy(busy: Boolean) {
        RecordingService.busy = busy
        if (::appContext.isInitialized) RecordingService.update(appContext)
    }
}

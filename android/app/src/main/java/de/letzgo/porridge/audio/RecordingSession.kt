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
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    /** Das Meeting, das diese Aufnahme fortsetzt. */
    private var continues: String? = null
    /** Nur Meetings lassen sich pausieren. */
    var isMeeting = false
        private set
    val isRecording: Boolean get() = recorder?.isRecording?.value == true
    val isPaused: Boolean get() = recorder?.isPaused?.value == true
    val isPausedForCall: Boolean get() = recorder?.isPausedForCall?.value == true
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

    /** Hält das Meeting fest, falls die App nicht bis zu seinem Ende kommt. */
    private var journal: RecordingJournal? = null
    private var journalNotes: Job? = null

    /** Startet eine Aufnahme mit Live-Transkript. Ein Meeting ([isMeeting]) bekommt ein Sicherungs-Journal, ein Diktat nicht. */
    fun start(title: String, withLive: Boolean = true, isMeeting: Boolean = false, meetingTitle: String? = null, continues: String? = null): AudioRecorder {
        check(!isRecording) { "Already recording." }
        notes.clear()
        this.continues = continues
        val rec = AudioRecorder(appContext)
        rec.onInterrupted = ::requestStop
        rec.pausesForCalls = isMeeting
        rec.onPauseChanged = ::pauseChangedByRecorder
        val transcriber = if (withLive) LiveTranscriber() else null
        val safety = if (isMeeting) runCatching { RecordingJournal(meetingTitle, continues) }.getOrNull() else null
        rec.onMono16k = { samples ->
            transcriber?.feed?.invoke(samples)
            safety?.append(samples)
        }
        try {
            rec.start()
        } catch (e: Throwable) {
            safety?.finish()
            throw e
        }
        journal = safety
        safety?.setUnfinishedFile(rec.fileName)
        journalNotes = safety?.let { j -> scope.launch { snapshotFlow { notes.toList() }.collect { j.setNotes(it) } } }
        recorder = rec
        live = transcriber
        this.title = title
        this.isMeeting = isMeeting
        startedAt = System.currentTimeMillis()
        RecordingService.update(appContext)
        transcriber?.let { scope.launch { it.start(Prefs.language.takeIf { l -> l != "auto" }) } }
        return rec
    }

    /** Die Uhr der Benachrichtigung steht in der Pause und läuft danach bei der aufgenommenen Zeit weiter. */
    fun setPaused(paused: Boolean, updateService: Boolean = true) {
        val rec = recorder ?: return
        rec.setPaused(paused)
        if (!paused) startedAt = System.currentTimeMillis() - (rec.elapsed.value * 1000).toLong()
        if (updateService) RecordingService.update(appContext)
    }

    /** Ein Anruf: Der Dienst läuft schon, also nur die Benachrichtigung neu zeichnen und die Uhr anpassen. */
    private fun pauseChangedByRecorder() {
        val rec = recorder ?: return
        if (!rec.isPaused.value) startedAt = System.currentTimeMillis() - (rec.elapsed.value * 1000).toLong()
        RecordingService.refresh(appContext)
    }

    /** Hält an; liefert die Aufnahme und den Live-Text. */
    suspend fun stop(): Pair<RecordingResult?, String> {
        // Das Schließen der Datei kann dauern und gehört nicht auf den Main-Thread.
        val result = withContext(Dispatchers.IO) { recorder?.stop() }
        // Das Journal bleibt, bis die Notiz gespeichert ist (`saveMeeting`).
        journalNotes?.cancel()
        if (result == null) endJournal()
        val text = live?.finish().orEmpty()
        recorder = null
        live = null
        RecordingService.update(appContext)
        return result to text
    }

    fun cancel() {
        journalNotes?.cancel()
        endJournal()
        recorder?.cancel()
        live?.cancel()
        recorder = null
        live = null
        RecordingService.update(appContext)
    }

    private fun endJournal() {
        journal?.finish()
        journal = null
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
        val target = continues?.let { PorridgeDatabase.shared.notes().get(it) }
        continues = null
        if (target != null && !target.isDeleted && target.pendingAudioFileName == null) {
            val updated = target.withRecordedPart(result.fileName, notes.toList())
            notes.clear()
            PorridgeDatabase.shared.notes().upsert(updated)
            endJournal()
            ProcessingService.enqueue(ProcessingService.Job.NoteAudio(updated.id))
            return updated
        }
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
        endJournal()
        ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
        return note
    }

    fun setBusy(busy: Boolean) {
        RecordingService.busy = busy
        if (::appContext.isInitialized) RecordingService.update(appContext)
    }
}

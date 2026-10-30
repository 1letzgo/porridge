package de.letzgo.porridge.processing

import de.letzgo.porridge.audio.AudioPreprocessor
import de.letzgo.porridge.cloud.SummaryService
import de.letzgo.porridge.data.LinkFetcher
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.logic.Paragraphs
import de.letzgo.porridge.logic.SpeakerAssigner
import de.letzgo.porridge.ml.Diarizer
import de.letzgo.porridge.ml.SpeechModel
import de.letzgo.porridge.ml.VoiceProfiles
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.store.ActionItemStore
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** iOS: `ProcessingService` (Services/ProcessingService.swift) — serielle Warteschlange, die Aufnahmen zu Transkripten macht. */
object ProcessingService {
    sealed interface Job {
        val id: String
        /** Eine Aufnahme bekommt ein Transkript mit Sprechern (`Note.audioFileName`). */
        data class Transcript(override val id: String) : Job
        /** Diktat-Audio wird an den Text der Notiz angehängt (`Note.pendingAudioFileName`). */
        data class NoteAudio(override val id: String) : Job
        /** Ein gespeicherter Link: Seite laden, dann (wahlweise) zusammenfassen. */
        data class Link(override val id: String, val summarize: Boolean) : Job
    }

    private val db get() = PorridgeDatabase.shared
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val queue = ArrayDeque<Job>()
    private var running = false

    /** Lesbarer Fortschritt je Notiz-ID. */
    private val _stages = MutableStateFlow<Map<String, String>>(emptyMap())
    val stages: StateFlow<Map<String, String>> = _stages.asStateFlow()

    /** Wird gerufen, solange Arbeit ansteht (der Vordergrunddienst hält die App wach). */
    var onBusyChanged: (Boolean) -> Unit = {}

    private fun stage(id: String, text: String?) = _stages.update { if (text == null) it - id else it + (id to text) }

    @Synchronized fun enqueue(job: Job) {
        if (queue.contains(job) || _stages.value.containsKey(job.id)) return
        queue.addLast(job)
        stage(job.id, "Waiting …")
        if (!running) {
            running = true
            onBusyChanged(true)
            scope.launch { run() }
        }
    }

    /** Nimmt Aufnahmen wieder auf, die unterbrochen wurden (App beendet während der Transkription). */
    suspend fun resumePending() {
        val notes = db.notes().all()
        for (note in notes) {
            if ((note.status == ProcessingStatus.RECORDED || note.status == ProcessingStatus.TRANSCRIBING) && note.hasLocalAudio && note.pendingAudioFileName == null) enqueue(Job.Transcript(note.id))
        }
        for (note in notes) if (AudioStore.exists(note.pendingAudioFileName)) enqueue(Job.NoteAudio(note.id))
        // Links ohne Zusammenfassung bekommen eine im Hintergrund, wenn ein Modell dafür bereit ist.
        for (note in notes) {
            if (note.isLink && !note.isDeleted && note.summary == null && note.status != ProcessingStatus.FAILED && (note.pageText == null || note.pageText.isNotEmpty())) {
                enqueue(Job.Link(note.id, summarize = true))
            }
        }
    }

    private suspend fun run() {
        while (true) {
            val job = synchronized(this) { queue.removeFirstOrNull() ?: run { running = false; null } } ?: break
            runCatching {
                when (job) {
                    is Job.Transcript -> processTranscript(job.id)
                    is Job.NoteAudio -> processNote(job.id)
                    is Job.Link -> processLink(job.id, job.summarize)
                }
            }
            stage(job.id, null)
        }
        onBusyChanged(false)
    }

    private suspend fun save(note: Note) = db.notes().upsert(note)

    // Aufnahmen mit Transkript

    private suspend fun processTranscript(id: String) {
        var meeting = db.notes().get(id) ?: return
        val fileName = meeting.audioFileName
        if (fileName == null || !AudioStore.exists(fileName)) {
            save(meeting.copy(statusRaw = ProcessingStatus.FAILED.raw, errorMessage = "The recording is not available on this device."))
            return
        }
        meeting = meeting.copy(statusRaw = ProcessingStatus.TRANSCRIBING.raw, errorMessage = null)
        save(meeting)
        try {
            stage(id, "Preparing audio …")
            val prepared = withContext(Dispatchers.IO) { AudioPreprocessor.prepare(AudioStore.file(fileName), meeting.speakerMode == SpeakerMode.CHANNELS) }
            stage(id, "Loading speech model …")
            SpeechModel.ensure()
            stage(id, "Transcribing …")
            val words = SpeechModel.transcribe(prepared.pcm, Prefs.language) { stage(id, "Transcribing … ${(it * 100).toInt()} %") }

            var speakers = meeting.speakers
            var diagnostics: String? = null
            var speakerIds: List<String?> = words.map { null }
            var mode = meeting.speakerMode
            var samples: FloatArray? = null

            val energy = prepared.channelEnergy
            if (energy != null) {
                speakerIds = SpeakerAssigner.byChannel(words, energy)
                listOf(SpeakerAssigner.LEFT_CHANNEL_ID, SpeakerAssigner.RIGHT_CHANNEL_ID).forEachIndexed { index, channelID ->
                    if (speakers.none { it.id == channelID }) speakers = speakers + Speaker(channelID, "Speaker ${index + 1}", index)
                }
            } else if (Prefs.speakerDetectionEnabled && words.isNotEmpty()) {
                stage(id, "Detecting speakers …")
                try {
                    Diarizer.ensure()
                    samples = prepared.floats()
                    val segments = Diarizer.diarize(samples)
                    val (ids, order) = SpeakerAssigner.byDiarization(words, segments)
                    diagnostics = if (order.isEmpty()) "Speaker detection found no speech (${segments.size} segments)." else null
                    if (order.isNotEmpty()) {
                        speakerIds = ids
                        speakers = order.mapIndexed { index, sid -> speakers.firstOrNull { it.id == sid } ?: Speaker(sid, "Speaker ${index + 1}", index) }
                        mode = SpeakerMode.DIARIZED
                    } else {
                        speakers = emptyList()
                        mode = SpeakerMode.NONE
                    }
                } catch (e: Throwable) {
                    // Sprechererkennung ist freiwillig; das Transkript bleibt.
                    diagnostics = "Speaker detection failed: ${e.message}"
                    speakers = emptyList()
                    mode = SpeakerMode.NONE
                }
            }

            var segments = SpeakerAssigner.group(words, speakerIds)
            // Sprecher ohne Text fallen weg (kurze Fehlerkennungen).
            val used = segments.mapNotNull { it.speakerId }.toSet()
            speakers = speakers.filter { it.id in used }
            if (mode == SpeakerMode.DIARIZED && speakers.isEmpty()) {
                mode = SpeakerMode.NONE
                segments = segments.map { it.copy(speakerId = null) }
            }
            if (segments.isEmpty() && words.isNotEmpty()) {
                segments = listOf(TranscriptSegment(start = 0.0, end = prepared.duration, text = words.joinToString(" ") { it.text }))
            }
            if (Prefs.voiceRecognitionEnabled && speakers.isNotEmpty()) {
                stage(id, "Recognizing voices …")
                speakers = VoiceProfiles().identify(speakers, segments, samples ?: prepared.floats())
            }
            val current = db.notes().get(id) ?: return
            save(
                current.copy(
                    speakerModeRaw = mode.raw, errorMessage = diagnostics, duration = prepared.duration,
                    statusRaw = ProcessingStatus.READY.raw, updatedAt = System.currentTimeMillis(),
                ).withSegments(segments).withSpeakers(speakers),
            )
        } catch (e: Throwable) {
            val current = db.notes().get(id) ?: return
            save(current.copy(statusRaw = ProcessingStatus.FAILED.raw, errorMessage = e.message ?: "Transcription failed."))
        }
    }

    // Diktat

    private suspend fun processNote(id: String) {
        val note = db.notes().get(id) ?: return
        val fileName = note.pendingAudioFileName ?: return
        if (!AudioStore.exists(fileName)) return
        save(note.copy(statusRaw = ProcessingStatus.TRANSCRIBING.raw, errorMessage = null))
        try {
            stage(id, "Preparing audio …")
            val prepared = withContext(Dispatchers.IO) { AudioPreprocessor.prepare(AudioStore.file(fileName), false) }
            stage(id, "Loading speech model …")
            SpeechModel.ensure()
            stage(id, "Transcribing …")
            val words = SpeechModel.transcribe(prepared.pcm, Prefs.language)
            val text = Paragraphs.format(words.joinToString(" ") { it.text }.trim())
            val current = db.notes().get(id) ?: return
            save(
                current.copy(
                    text = if (text.isEmpty()) current.text else if (current.text.isEmpty()) text else current.text + "\n\n" + text,
                    audioFileNames = current.audioFileNames + fileName,
                    pendingAudioFileName = null,
                    updatedAt = System.currentTimeMillis(),
                    statusRaw = ProcessingStatus.READY.raw,
                ),
            )
        } catch (e: Throwable) {
            val current = db.notes().get(id) ?: return
            save(current.copy(statusRaw = ProcessingStatus.FAILED.raw, errorMessage = e.message))
        }
    }

    // Links

    private suspend fun processLink(id: String, summarize: Boolean) {
        var note = db.notes().get(id) ?: return
        val address = note.url ?: return
        // Die Seite wird einmal geladen; „Load Page Again“ und ein neuer Link (Status recorded) laden sie.
        if (note.pageText == null || note.status == ProcessingStatus.RECORDED) {
            stage(id, "Loading page …")
            try {
                val page = LinkFetcher.fetch(address)
                val keepTitle = !(note.title.isEmpty() || note.title == address || note.title == note.domain)
                note = note.copy(
                    pageText = page.text,
                    title = if (page.title != null && !keepTitle) page.title else note.title,
                    statusRaw = ProcessingStatus.READY.raw, errorMessage = null,
                )
                save(note)
            } catch (e: Throwable) {
                save(note.copy(statusRaw = ProcessingStatus.FAILED.raw, errorMessage = e.message))
                return
            }
        }
        if (summarize && note.summary == null && !note.isDeleted && !note.pageText.isNullOrEmpty() && SummaryService.canRunWithoutAsking) {
            stage(id, "Summarizing …")
            runCatching { SummaryService.summarize(note) { stage(id, it) } }.onSuccess { summarized ->
                save(summarized)
                ActionItemStore().sync(summarized)
            }
        }
    }

    /** Fasst eine Notiz auf Wunsch zusammen (Knopf in der Notiz). */
    suspend fun summarize(id: String) {
        val note = db.notes().get(id) ?: return
        stage(id, "Summarizing …")
        try {
            val summarized = SummaryService.summarize(note) { stage(id, it) }
            save(summarized)
            ActionItemStore().sync(summarized)
        } finally {
            stage(id, null)
        }
    }
}

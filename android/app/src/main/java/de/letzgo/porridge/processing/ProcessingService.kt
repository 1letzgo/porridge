package de.letzgo.porridge.processing

import de.letzgo.porridge.audio.AudioPreprocessor
import de.letzgo.porridge.audio.PreparedAudio
import de.letzgo.porridge.cloud.SummaryModel
import de.letzgo.porridge.cloud.SummaryService
import de.letzgo.porridge.data.LinkFetcher
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.logic.SummaryTemplate
import de.letzgo.porridge.logic.Paragraphs
import de.letzgo.porridge.logic.SpeakerAssigner
import de.letzgo.porridge.logic.SummaryLogic
import de.letzgo.porridge.ml.Diarizer
import de.letzgo.porridge.ml.SpeechModel
import de.letzgo.porridge.ml.VoiceProfiles
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.NoteMerger
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * iOS: `ProcessingService` (Services/ProcessingService.swift) — serielle Warteschlange, die Aufnahmen zu Transkripten macht,
 * Seiten lädt, Text aus Dateien liest und hereingekommene Einträge zusammenfasst (`logic/AutoSummary.kt`).
 */
object ProcessingService {
    sealed interface Job {
        val id: String
        /** Eine Aufnahme bekommt ein Transkript mit Sprechern (`Note.audioFileName`). */
        data class Transcript(override val id: String) : Job
        /** Diktat-Audio wird an den Text der Notiz angehängt (`Note.pendingAudioFileName`). */
        data class NoteAudio(override val id: String) : Job
        /** Ein gespeicherter Link: Seite laden, dann (wahlweise) zusammenfassen. */
        data class Link(override val id: String, val summarize: Boolean) : Job
        /** Die Zusammenfassung, um die jemand gebeten hat. */
        data class Summary(override val id: String, val template: SummaryTemplate, val model: SummaryModel? = null) : Job
        /** Der eigene Text einer einfachen Notiz wird von KI umgeschrieben (`SummaryService.enhance`). */
        data class Enhance(override val id: String, val model: SummaryModel? = null) : Job
        /** Eine Notiz mit Anhängen: den Text ihrer Bilder und PDFs lesen, dann zusammenfassen. */
        data class Attachment(override val id: String) : Job
        /** Die Zusammenfassung eines hereingekommenen Eintrags, um die niemand bat (`AutoSummary`). */
        data class AutoSummary(override val id: String) : Job
    }

    private val db get() = PorridgeDatabase.shared
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val queue = ArrayDeque<Job>()
    private var running = false
    /** Die Arbeit, die gerade läuft. */
    private var current: Job? = null
    private val autoAttempts = de.letzgo.porridge.logic.AutoSummary.Attempts()
    private var sweep: kotlinx.coroutines.Job? = null

    /** Lesbarer Fortschritt je Notiz-ID. */
    private val _stages = MutableStateFlow<Map<String, String>>(emptyMap())
    val stages: StateFlow<Map<String, String>> = _stages.asStateFlow()

    /** Notizen, deren Zusammenfassung wartet oder gerade entsteht. */
    private val _summarizing = MutableStateFlow<Set<String>>(emptySet())
    val summarizing: StateFlow<Set<String>> = _summarizing.asStateFlow()

    /** Das für eine Zusammenfassung gewählte Modell, wenn es nicht der Standard ist. */
    private val _summaryModels = MutableStateFlow<Map<String, SummaryModel>>(emptyMap())
    val summaryModels: StateFlow<Map<String, SummaryModel>> = _summaryModels.asStateFlow()
    /** Warum eine Zusammenfassung scheiterte, bis die Notiz es gezeigt hat (ihr Bildschirm ist dann vielleicht längst zu). */
    private val _summaryErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    val summaryErrors: StateFlow<Map<String, String>> = _summaryErrors.asStateFlow()

    fun clearSummaryError(id: String) = _summaryErrors.update { it - id }

    /** Notizen, deren Text auf das Verbessern wartet oder gerade verbessert wird. */
    private val _enhancing = MutableStateFlow<Set<String>>(emptySet())
    val enhancing: StateFlow<Set<String>> = _enhancing.asStateFlow()
    private val _enhanceErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    val enhanceErrors: StateFlow<Map<String, String>> = _enhanceErrors.asStateFlow()
    fun clearEnhanceError(id: String) = _enhanceErrors.update { it - id }

    /** Text vor und nach dem letzten Verbessern, solange die App läuft: Rückgängig nur, solange der neue Text unverändert ist. */
    data class EnhanceUndo(val original: String, val enhanced: String)
    private val _enhanceUndo = MutableStateFlow<Map<String, EnhanceUndo>>(emptyMap())
    val enhanceUndo: StateFlow<Map<String, EnhanceUndo>> = _enhanceUndo.asStateFlow()

    /** Holt den Text von vor dem letzten Verbessern zurück. */
    suspend fun undoEnhance(id: String) {
        val undo = _enhanceUndo.value[id] ?: return
        val current = db.notes().get(id) ?: return
        if (current.text != undo.enhanced) return
        save(current.copy(text = undo.original, updatedAt = System.currentTimeMillis()))
        _enhanceUndo.update { it - id }
    }

    /** Wird gerufen, solange Arbeit ansteht (der Vordergrunddienst hält die App wach). */
    var onBusyChanged: (Boolean) -> Unit = {}

    private fun stage(id: String, text: String?) = _stages.update { if (text == null) it - id else it + (id to text) }

    @Synchronized fun enqueue(job: Job) {
        // iOS: `enqueue` — dieselbe Art Arbeit für dieselbe Notiz nur einmal; eine andere Art wartet, bis sie dran ist.
        fun same(other: Job?) = other != null && other.id == job.id && other::class == job::class
        if (queue.any { same(it) } || same(current)) return
        queue.addLast(job)
        if (!_stages.value.containsKey(job.id)) stage(job.id, "Waiting…")
        if (job is Job.Summary) {
            _summarizing.update { it + job.id }
            job.model?.let { model -> _summaryModels.update { it + (job.id to model) } }
        }
        if (job is Job.Enhance) _enhancing.update { it + job.id }
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
        // Anhänge, deren Text noch nicht gelesen ist (die App wurde vorher geschlossen).
        for (note in notes) {
            if (note.attachmentsData != null && !note.isDeleted && !note.isRecording && (note.pageText == null || note.status == ProcessingStatus.RECORDED)) enqueue(Job.Attachment(note.id))
        }
        // iOS: `resumePending` — nichts mehr zu tun (die Datei ist weg): So eine Notiz wartete für immer und käme nie in den Abgleich.
        for (note in notes) {
            if (note.isLink || note.attachmentsData != null) continue
            val pendingLost = note.pendingAudioFileName != null && !AudioStore.exists(note.pendingAudioFileName)
            val stuck = (note.status == ProcessingStatus.RECORDED || note.status == ProcessingStatus.TRANSCRIBING) && !note.hasLocalAudio && !AudioStore.exists(note.pendingAudioFileName)
            if (!pendingLost && !stuck) continue
            val current = db.notes().get(note.id) ?: continue
            val empty = current.segments.isEmpty() && current.text.isEmpty() && current.audioFileName == null
            save(
                current.copy(
                    pendingAudioFileName = if (pendingLost) null else current.pendingAudioFileName,
                    statusRaw = (if (empty) ProcessingStatus.FAILED else ProcessingStatus.READY).raw,
                    errorMessage = if (empty) "The recording is not available on this device." else current.errorMessage,
                ),
            )
        }
        // Links, deren Seite noch nicht geladen ist (die App wurde vorher geschlossen).
        for (note in notes) {
            if (note.isLink && !note.isDeleted && note.status != ProcessingStatus.FAILED && (note.pageText == null || note.status == ProcessingStatus.RECORDED)) {
                enqueue(Job.Link(note.id, summarize = true))
            }
        }
        de.letzgo.porridge.logic.AutoSummary.origins.prune(db.notes().all())
        summarizeIncoming()
    }

    // Zusammenfassungen hereingekommener Einträge

    /**
     * iOS: `summarizeIncoming` — reiht die Zusammenfassung jedes hereingekommenen Eintrags ein, der fällig ist
     * (`AutoSummary.isDue`). Gerufen beim Start, wenn die App nach vorn kommt und wenn sich die Notizen ändern (neue
     * Einträge, Sync): billig, wenn nichts fällig ist.
     */
    suspend fun summarizeIncoming() {
        // Von Zeit zu Zeit wieder angesehen: Ein gescheiterter wird wieder versucht, der Eintrag eines anderen Geräts kann
        // zum Nachholen fällig sein, ein Modell kann gekommen sein.
        synchronized(this) {
            if (sweep == null) sweep = scope.launch {
                kotlinx.coroutines.delay(de.letzgo.porridge.logic.AutoSummary.RETRY_DELAY)
                synchronized(this@ProcessingService) { sweep = null }
                summarizeIncoming()
            }
        }
        if (!de.letzgo.porridge.logic.AutoSummary.enabled || !SummaryService.canRunWithoutAsking) return
        val origins = de.letzgo.porridge.logic.AutoSummary.origins.all()
        for (note in db.notes().all()) {
            if (note.summary != null || note.summarizedAt != null || note.isDeleted) continue
            if (autoAttempts.mayTry(note.id) && de.letzgo.porridge.logic.AutoSummary.isDue(note, isOrigin = note.id in origins)) enqueue(Job.AutoSummary(note.id))
        }
    }

    /** Gleich nachdem der Inhalt eines Eintrags kam (Seite geladen, Text gelesen, Transkript fertig). */
    private fun summarizeIfIncoming(note: Note) {
        if (!de.letzgo.porridge.logic.AutoSummary.enabled || !SummaryService.canRunWithoutAsking || !autoAttempts.mayTry(note.id)) return
        if (!de.letzgo.porridge.logic.AutoSummary.isDue(note, isOrigin = de.letzgo.porridge.logic.AutoSummary.origins.contains(note.id))) return
        enqueue(Job.AutoSummary(note.id))
    }

    private suspend fun processAutoSummary(id: String) {
        // Noch einmal geprüft: Sie kann inzwischen zusammengefasst, bearbeitet oder gelöscht worden sein.
        val auto = de.letzgo.porridge.logic.AutoSummary
        val note = db.notes().get(id) ?: return
        if (!SummaryService.canRunWithoutAsking || !auto.isDue(note, isOrigin = auto.origins.contains(id))) return
        stage(id, "Summarizing…")
        try {
            val summarized = SummaryService.summarize(note) { stage(id, it) }
            saveSummary(note, summarized, onlyIfEmpty = true)
            autoAttempts.succeeded(id)
            auto.origins.clear(id)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Kein Modell, keine Verbindung, keine Antwort: still später wieder (`AutoSummary.RETRY_DELAY`).
            autoAttempts.failed(id)
        }
    }

    private suspend fun run() {
        while (true) {
            val job = synchronized(this) { (queue.removeFirstOrNull() ?: run { running = false; null }).also { current = it } } ?: break
            runCatching {
                when (job) {
                    is Job.Transcript -> processTranscript(job.id)
                    is Job.NoteAudio -> processNote(job.id)
                    is Job.Link -> processLink(job.id, job.summarize)
                    is Job.Summary -> processSummary(job.id, job.template, job.model)
                    is Job.Enhance -> processEnhance(job.id, job.model)
                    is Job.Attachment -> processAttachments(job.id)
                    is Job.AutoSummary -> processAutoSummary(job.id)
                }
            }
            synchronized(this) {
                current = null
                // Auf diese Notiz kann noch andere Arbeit warten: Ihre Zeichen bleiben.
                val waiting = queue.filter { it.id == job.id }
                stage(job.id, if (waiting.isEmpty()) null else "Waiting…")
                if (waiting.none { it is Job.Summary }) {
                    _summarizing.update { it - job.id }
                    _summaryModels.update { it - job.id }
                }
                if (waiting.none { it is Job.Enhance }) _enhancing.update { it - job.id }
            }
        }
        onBusyChanged(false)
    }

    private suspend fun save(note: Note) = db.notes().upsert(note)

    /**
     * Eine inzwischen gelöschte Notiz bleibt gelöscht. [onlyIfEmpty] (eine Zusammenfassung, um die niemand bat): Nichts wird
     * geschrieben, wenn inzwischen eine geschrieben, bearbeitet oder gelöscht wurde (iOS: `summarize(onlyIfEmpty:)`).
     */
    private suspend fun saveSummary(before: Note, summarized: Note, onlyIfEmpty: Boolean = false) {
        val current = db.notes().get(before.id) ?: return
        if (onlyIfEmpty && (current.summary != null || current.summarizedAt != null || current.isDeleted)) return
        val updated = SummaryLogic.carryOver(summarized, before, current)
        save(updated)
    }

    /** iOS: `processAttachments` — liest den Text der Bilder, PDFs und Textdateien in `pageText` und fasst ihn zusammen. */
    private suspend fun processAttachments(id: String) {
        val note = db.notes().get(id) ?: return
        stage(id, "Reading text…")
        val text = readAttachments(note)
        val read = de.letzgo.porridge.store.NoteStore(db).update(id) { it.copy(statusRaw = ProcessingStatus.READY.raw, errorMessage = null) } ?: return
        if (text.isNotEmpty()) summarizeIfIncoming(read)
    }

    /**
     * iOS: `readAttachments` — liest den Text der Dateien in `pageText` und gibt ihn zurück. Eine Datei, die nur auf einem
     * anderen Gerät liegt, wird vorher geholt; fehlt eine und wurde nichts gelesen, gilt die Notiz als noch nicht
     * angesehen (`pageText` bleibt null), damit der Text gelesen wird, sobald die Datei da ist.
     */
    private suspend fun readAttachments(note: Note): String {
        for (attachment in note.attachments) if (!AudioStore.exists(attachment.fileName)) {
            runCatching { de.letzgo.porridge.sync.NextcloudSync.fetchRecording(attachment.fileName) }
        }
        val present = note.attachments.filter { AudioStore.exists(it.fileName) }
        val text = de.letzgo.porridge.data.AttachmentText.read(present.map { AudioStore.file(it.fileName) to it })
        // "" = angesehen, nichts zu lesen (ein Foto ohne Text).
        if (text.isNotEmpty() || present.size == note.attachments.size) de.letzgo.porridge.store.NoteStore(db).update(note.id, touch = false) { it.copy(pageText = text) }
        return text
    }

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
            val result = recognize(id, fileName, meeting.speakerMode, meeting.speakers)
            val current = db.notes().get(id) ?: return
            val done = current.copy(
                speakerModeRaw = result.mode.raw, errorMessage = result.diagnostics, duration = result.duration,
                statusRaw = ProcessingStatus.READY.raw, updatedAt = System.currentTimeMillis(),
            ).withSegments(result.segments).withSpeakers(result.speakers)
            save(done)
            // Importiertes Audio wird von selbst zusammengefasst; die eigenen Aufnahmen auf Wunsch.
            summarizeIfIncoming(done)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val current = db.notes().get(id) ?: return
            save(current.copy(statusRaw = ProcessingStatus.FAILED.raw, errorMessage = e.message ?: "Transcription failed."))
        }
    }

    private class Recognized(val segments: List<TranscriptSegment>, val speakers: List<Speaker>, val mode: SpeakerMode, val diagnostics: String?, val duration: Double)

    /** Transkript und Sprecher einer Aufnahme. */
    private suspend fun recognize(id: String, fileName: String, startMode: SpeakerMode, startSpeakers: List<Speaker>): Recognized {
        stage(id, "Preparing audio…")
        val prepared = withContext(Dispatchers.IO) { AudioPreprocessor.prepare(AudioStore.file(fileName), startMode == SpeakerMode.CHANNELS) }
        return try {
            recognize(id, prepared, startMode, startSpeakers)
        } finally {
            prepared.close()
        }
    }

    private suspend fun recognize(id: String, prepared: PreparedAudio, startMode: SpeakerMode, startSpeakers: List<Speaker>): Recognized {
        stage(id, "Loading speech model…")
        SpeechModel.ensure()
        stage(id, "Transcribing…")
        val words = SpeechModel.transcribe(prepared, Prefs.language) { stage(id, "Transcribing … ${(it * 100).toInt()} %") }

        var speakers = startSpeakers
        var diagnostics: String? = null
        var speakerIds: List<String?> = words.map { null }
        var mode = startMode
        var samples: FloatArray? = null

        val energy = prepared.channelEnergy
        if (energy != null) {
            speakerIds = SpeakerAssigner.byChannel(words, energy)
            listOf(SpeakerAssigner.LEFT_CHANNEL_ID, SpeakerAssigner.RIGHT_CHANNEL_ID).forEachIndexed { index, channelID ->
                if (speakers.none { it.id == channelID }) speakers = speakers + Speaker(channelID, "Speaker ${index + 1}", index)
            }
        } else if (Prefs.speakerDetectionEnabled && words.isNotEmpty()) {
            stage(id, "Detecting speakers…")
            try {
                Diarizer.ensure()
                // Am Stück im Speicher, weil die Diarisierung es so will; reicht er nicht, bleibt das Transkript ohne Sprecher.
                samples = try {
                    prepared.floats()
                } catch (e: OutOfMemoryError) {
                    throw IllegalStateException("the recording is too long for this device")
                }
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
            stage(id, "Recognizing voices…")
            try {
                speakers = VoiceProfiles().identify(speakers, segments, samples ?: prepared.floats())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // Stimmen sind freiwillig; das fertige Transkript bleibt.
                diagnostics = "Voice recognition failed: ${e.message}"
            }
        }
        return Recognized(segments, speakers, mode, diagnostics, prepared.duration)
    }

    /**
     * Ein Meeting wurde weiter aufgenommen: Der neue Teil bekommt ein eigenes Transkript und kommt dann dazu. Er wartet in
     * `pendingAudioFileName`; ein Fehler oder Neustart verliert nichts.
     */
    private suspend fun processContinuation(id: String, fileName: String) {
        val before = db.notes().get(id) ?: return
        save(before.copy(statusRaw = ProcessingStatus.TRANSCRIBING.raw, errorMessage = null))
        try {
            val stereo = AudioStore.audioInfo(fileName)?.second == 2
            val result = recognize(id, fileName, if (stereo) SpeakerMode.CHANNELS else SpeakerMode.NONE, emptyList())
            stage(id, "Adding to the meeting…")
            val part = Note(createdAt = System.currentTimeMillis(), audioFileName = fileName, duration = result.duration, errorMessage = result.diagnostics)
                .withSegments(result.segments).withSpeakers(result.speakers)
            val current = db.notes().get(id) ?: return
            NoteMerger(db).append(part, current)
        } catch (e: CancellationException) {
            throw e
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
        if (note.isRecording) {
            processContinuation(id, fileName)
            return
        }
        save(note.copy(statusRaw = ProcessingStatus.TRANSCRIBING.raw, errorMessage = null))
        try {
            stage(id, "Preparing audio…")
            val prepared = withContext(Dispatchers.IO) { AudioPreprocessor.prepare(AudioStore.file(fileName), false) }
            val words = try {
                stage(id, "Loading speech model…")
                SpeechModel.ensure()
                stage(id, "Transcribing…")
                SpeechModel.transcribe(prepared, Prefs.language)
            } finally {
                prepared.close()
            }
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
        } catch (e: CancellationException) {
            throw e
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
            stage(id, "Loading page…")
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
        if (summarize) db.notes().get(id)?.let { summarizeIfIncoming(it) }
    }

    /** iOS: `processEnhance` — schreibt den Text einer einfachen Notiz um; der alte Text bleibt für Rückgängig. */
    private suspend fun processEnhance(id: String, model: SummaryModel?) {
        val note = db.notes().get(id) ?: return
        stage(id, "Enhancing note…")
        try {
            val raw = SummaryService.enhance(note.text, model) { stage(id, it) }
            val current = db.notes().get(id) ?: return
            val enhanced = SummaryLogic.applyEnhance(current, note.text, raw)
            save(enhanced)
            _enhanceUndo.update { it + (id to EnhanceUndo(note.text, enhanced.text)) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            _enhanceErrors.update { it + (id to (e.message ?: "The note could not be enhanced.")) }
        }
    }

    /** Fasst eine Notiz auf Wunsch zusammen (Knopf in der Notiz). */
    private suspend fun processSummary(id: String, template: SummaryTemplate, model: SummaryModel?) {
        var note = db.notes().get(id) ?: return
        try {
            // Ein Bild oder eine Datei wird aus dem zusammengefasst, was daraus gelesen wurde: jetzt lesen, wenn das noch
            // nicht geschehen ist (die Datei kam von einem anderen Gerät, oder das Lesen wurde abgebrochen).
            if (note.attachmentsData != null && !note.isRecording && note.pageText.isNullOrEmpty()) {
                stage(id, "Reading text…")
                readAttachments(note)
                note = db.notes().get(id) ?: return
            }
            stage(id, "Summarizing…")
            saveSummary(note, SummaryService.summarize(note, template, model) { stage(id, it) })
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val message = e.message ?: "The summary could not be written."
            _summaryErrors.update { it + (id to message) }
        }
    }
}

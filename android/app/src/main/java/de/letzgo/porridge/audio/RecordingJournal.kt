package de.letzgo.porridge.audio

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.RecordingNote
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * iOS: `RecordingJournal` — eine Sicherheitskopie des laufenden Meetings. Die m4a einer Aufnahme ist erst lesbar, wenn sie
 * geschlossen ist, und ihre Notiz entsteht danach; ein Absturz oder ein Beenden der App kostete sonst alles. Hier läuft der
 * Ton fortlaufend und roh mit (16 kHz mono), neben dem, was das Meeting für eine Notiz braucht. Ein normales Ende löscht die
 * Kopie; liegt beim nächsten Start noch eine da, wird sie das Meeting ([recover]).
 */
class RecordingJournal(title: String?, continues: String? = null) {
    @Serializable
    private data class Info(val title: String?, val startedAt: Long, val unfinishedFile: String? = null, val notes: List<StoredNote> = emptyList(), val continues: String? = null)

    @Serializable
    private data class StoredNote(val at: Double, val text: String)

    private val id = UUID.randomUUID().toString()
    private val soundFile = File(folder, "$id.pcm")
    private val infoFile = File(folder, "$id.json")
    private val raw = FileOutputStream(soundFile)
    private val stream = BufferedOutputStream(raw, 32 * 1024)
    private var info = Info(title, System.currentTimeMillis(), continues = continues)
    private var lastSync = System.currentTimeMillis()
    private var closed = false

    init {
        activeID = id
        saveInfo()
    }

    @Synchronized fun setUnfinishedFile(name: String?) {
        info = info.copy(unfinishedFile = name)
        saveInfo()
    }

    @Synchronized fun setNotes(notes: List<RecordingNote>) {
        info = info.copy(notes = notes.map { StoredNote(it.at, it.text) })
        saveInfo()
    }

    /** 16-kHz-Mono vom Thread des Recorders. Eine volle Platte kostet nur die Kopie, nicht die Aufnahme. */
    @Synchronized fun append(samples: FloatArray) {
        if (closed) return
        runCatching {
            val bytes = ByteArray(samples.size * 2)
            samples.forEachIndexed { i, sample ->
                val value = (sample.coerceIn(-1f, 1f) * 32767f).toInt()
                bytes[i * 2] = value.toByte()
                bytes[i * 2 + 1] = (value shr 8).toByte()
            }
            stream.write(bytes)
            stream.flush()
            // Das System hält, was geschrieben ist, wenn die App endet; dies ist für ein Gerät, das ausgeht.
            if (System.currentTimeMillis() - lastSync > 10_000) {
                lastSync = System.currentTimeMillis()
                raw.fd.sync()
            }
        }
    }

    /** Die Aufnahme ist zu Ende und hat ihre Notiz, oder sie wurde verworfen. */
    @Synchronized fun finish() {
        if (!closed) {
            closed = true
            runCatching { stream.close() }
        }
        soundFile.delete()
        infoFile.delete()
        if (activeID == id) activeID = null
    }

    private fun saveInfo() {
        runCatching {
            val tmp = File(infoFile.path + ".tmp")
            tmp.writeText(PorridgeJson.encodeToString(Info.serializer(), info))
            tmp.renameTo(infoFile)
        }
    }

    companion object {
        private const val SAMPLE_RATE = 16_000
        private val folder: File get() = File(AudioStore.directory.parentFile, "RecordingJournal").apply { mkdirs() }
        @Volatile private var activeID: String? = null

        /** Macht aus jeder Aufnahme, die nicht zu Ende kam, ein Meeting. Zu kurz für eines: wird nur weggeräumt. */
        suspend fun recover() = withContext(Dispatchers.IO) {
            val active = activeID
            for (infoFile in folder.listFiles { file -> file.extension == "json" && file.nameWithoutExtension != active }.orEmpty()) {
                val sound = File(folder, infoFile.nameWithoutExtension + ".pcm")
                val info = runCatching { PorridgeJson.decodeFromString(Info.serializer(), infoFile.readText()) }.getOrNull()
                if (info != null) {
                    runCatching { encode(sound) }.getOrNull()?.let { (fileName, duration) ->
                        // Weg oder wartet schon auf einen anderen Teil: Die Aufnahme wird ein eigenes Meeting.
                        val meeting = info.continues?.let { PorridgeDatabase.shared.notes().get(it) }?.takeIf { !it.isDeleted && it.pendingAudioFileName == null }
                        if (meeting != null) {
                            PorridgeDatabase.shared.notes().upsert(meeting.withRecordedPart(fileName, info.notes.map { RecordingNote(it.at, it.text) }))
                            ProcessingService.enqueue(ProcessingService.Job.NoteAudio(meeting.id))
                            return@let
                        }
                        val note = Note(
                            title = info.title ?: Note.defaultMeetingTitle(info.startedAt), titleIsCustom = info.title != null,
                            createdAt = info.startedAt, updatedAt = info.startedAt, statusRaw = ProcessingStatus.RECORDED.raw,
                            audioFileName = fileName, duration = duration, channelCount = 1, inputName = "Recovered",
                            text = RecordingNote.markdown(info.notes.map { RecordingNote(it.at, it.text) }),
                        )
                        PorridgeDatabase.shared.notes().upsert(note)
                        ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
                    }
                    AudioStore.delete(info.unfinishedFile)
                }
                sound.delete()
                infoFile.delete()
            }
        }

        /** Der rohe Ton als m4a im [AudioStore]; null bei weniger als einer Sekunde. */
        private fun encode(sound: File): Pair<String, Double>? {
            if (sound.length() < SAMPLE_RATE * 2L) return null
            val name = AudioStore.newFileName()
            val writer = AacWriter(AudioStore.file(name), SAMPLE_RATE, 1)
            try {
                sound.inputStream().buffered().use { input ->
                    val bytes = ByteArray(SAMPLE_RATE * 2)
                    while (true) {
                        var read = 0
                        while (read < bytes.size) {
                            val n = input.read(bytes, read, bytes.size - read)
                            if (n < 0) break
                            read += n
                        }
                        if (read < 2) break
                        val samples = ShortArray(read / 2) { i -> ((bytes[i * 2 + 1].toInt() shl 8) or (bytes[i * 2].toInt() and 0xFF)).toShort() }
                        writer.write(samples, samples.size)
                    }
                }
            } finally {
                writer.close()
            }
            return name to writer.duration
        }
    }
}

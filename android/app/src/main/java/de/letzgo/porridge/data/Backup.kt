package de.letzgo.porridge.data

import android.content.Context
import android.net.Uri
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Android-eigen (iOS synchronisiert über iCloud): Sicherung als eine Zip-Datei mit Notizen, Ordnern, Stimmen,
 * Aufgaben und den Aufnahmen. Einspielen führt zusammen: gleiche ID, neuere Änderung gewinnt.
 */
object Backup {
    @Serializable
    data class Contents(
        val version: Int = 1,
        val notes: List<Note>,
        val folders: List<NoteFolder>,
        val voiceProfiles: List<VoiceProfile>,
        val actionItems: List<ActionItem>,
    )

    data class Result(val notes: Int, val recordings: Int)

    suspend fun export(context: Context, target: Uri): Result = withContext(Dispatchers.IO) {
        val db = PorridgeDatabase.shared
        val notes = db.notes().all()
        val contents = Contents(notes = notes, folders = db.folders().all(), voiceProfiles = db.voiceProfiles().all(), actionItems = db.actionItems().all())
        var recordings = 0
        context.contentResolver.openOutputStream(target)!!.use { out ->
            ZipOutputStream(out).use { zip ->
                zip.putNextEntry(ZipEntry("porridge.json"))
                zip.write(PorridgeJson.encodeToString(Contents.serializer(), contents).toByteArray())
                zip.closeEntry()
                val files = notes.flatMap { listOfNotNull(it.audioFileName, it.pendingAudioFileName) + it.audioFileNames }.toSet()
                for (name in files) {
                    val file = AudioStore.file(name)
                    if (!file.exists()) continue
                    zip.putNextEntry(ZipEntry("recordings/$name"))
                    file.inputStream().use { it.copyTo(zip) }
                    zip.closeEntry()
                    recordings++
                }
            }
        }
        Result(notes.size, recordings)
    }

    suspend fun import(context: Context, source: Uri): Result = withContext(Dispatchers.IO) {
        val db = PorridgeDatabase.shared
        var contents: Contents? = null
        var recordings = 0
        context.contentResolver.openInputStream(source)!!.use { input ->
            ZipInputStream(input).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    when {
                        entry.name == "porridge.json" -> contents = PorridgeJson.decodeFromString(Contents.serializer(), zip.readBytes().decodeToString())
                        entry.name.startsWith("recordings/") && !entry.isDirectory -> {
                            val name = entry.name.removePrefix("recordings/")
                            // Nur einfache Dateinamen (kein Pfad aus dem Archiv).
                            if (name.isNotEmpty() && '/' !in name && !name.startsWith(".")) {
                                val file = AudioStore.file(name)
                                if (!file.exists()) { file.outputStream().use { zip.copyTo(it) }; recordings++ }
                            }
                        }
                    }
                }
            }
        }
        val data = contents ?: error("This is not a Porridge backup.")
        val existing = db.notes().all().associateBy { it.id }
        db.notes().upsertAll(data.notes.filter { n -> existing[n.id]?.let { it.updatedAt < n.updatedAt } ?: true })
        val folders = db.folders().all().map { it.id }.toSet()
        db.folders().upsertAll(data.folders.filter { it.id !in folders })
        val profiles = db.voiceProfiles().all().associateBy { it.id }
        db.voiceProfiles().upsertAll(data.voiceProfiles.filter { p -> profiles[p.id]?.let { it.updatedAt < p.updatedAt } ?: true })
        val items = db.actionItems().all().map { it.id }.toSet()
        db.actionItems().upsertAll(data.actionItems.filter { it.id !in items })
        Result(data.notes.size, recordings)
    }
}

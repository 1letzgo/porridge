package de.letzgo.porridge.store

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.File
import java.util.UUID

/** iOS: `AudioStore` — lokaler, nicht synchronisierter Speicher für Aufnahmen (`filesDir/Recordings`). */
object AudioStore {
    lateinit var directory: File
        private set

    fun init(context: Context) {
        directory = File(context.filesDir, "Recordings").apply { mkdirs() }
    }

    /** Für Unit-Tests. */
    internal fun initForTests(dir: File) {
        directory = dir.apply { mkdirs() }
    }

    fun file(fileName: String) = File(directory, fileName)

    fun newFileName(extension: String = "m4a") = "${UUID.randomUUID().toString().uppercase()}.$extension"

    fun exists(fileName: String?): Boolean = fileName != null && ::directory.isInitialized && file(fileName).exists()

    fun delete(fileName: String?) {
        if (fileName != null) file(fileName).delete()
    }

    /** Kopiert eine fremde Audio-/Videodatei in den Speicher und gibt den neuen Namen zurück. */
    fun importFile(context: Context, source: Uri, extension: String?): String {
        val name = newFileName(extension?.lowercase()?.ifEmpty { null } ?: "m4a")
        context.contentResolver.openInputStream(source).use { input ->
            requireNotNull(input) { "The file could not be read." }
            file(name).outputStream().use { input.copyTo(it) }
        }
        return name
    }

    /** Dauer in Sekunden und Kanalzahl der ersten Tonspur. */
    fun audioInfo(fileName: String): Pair<Double, Int>? = runCatching {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file(fileName).absolutePath)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    val duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else 0.0
                    return@runCatching duration to format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
            }
            null
        } finally {
            extractor.release()
        }
    }.getOrNull()
}

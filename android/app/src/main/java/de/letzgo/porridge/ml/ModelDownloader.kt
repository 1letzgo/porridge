package de.letzgo.porridge.ml

import de.letzgo.porridge.data.Net
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/**
 * Lädt die Dateien eines [ModelPack]: in eine `.part`-Datei, die ein abgebrochener Download fortsetzt (HTTP Range),
 * und erst nach geprüfter Prüfsumme an ihren Platz. iOS: Download in FluidAudio/swift-huggingface.
 */
object ModelDownloader {
    suspend fun download(pack: ModelPack, root: File, progress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val dir = pack.directory(root).apply { mkdirs() }
        val total = pack.bytes.toFloat()
        var before = 0L
        for (file in pack.files) {
            val target = File(dir, file.name)
            if (target.exists() && target.length() >= file.bytes * 95 / 100) {
                before += file.bytes
                continue
            }
            val part = File(dir, file.name + ".part")
            fetchRetrying(file, part) { done -> progress(((before + done) / total).coerceIn(0f, 1f)) }
            file.sha256?.let { expected ->
                val actual = sha256(part)
                if (!actual.equals(expected, ignoreCase = true)) {
                    part.delete()
                    error("The download of ${pack.displayName} is damaged. Please try again.")
                }
            }
            check(part.renameTo(target)) { "Could not store ${file.name}." }
            before += file.bytes
        }
        progress(1f)
    }

    /**
     * Bricht die Verbindung ab (Netzwechsel, Funkloch, App im Hintergrund), geht es nach einer Pause dort weiter, wo
     * die `.part`-Datei aufhört. Aufgegeben wird erst nach mehreren Versuchen ohne jeden Fortschritt.
     */
    private suspend fun fetchRetrying(file: ModelFile, part: File, progress: (Long) -> Unit) {
        var failures = 0
        while (true) {
            val before = if (part.exists()) part.length() else 0L
            try {
                fetch(file, part, progress)
                return
            } catch (e: IOException) {
                val advanced = part.exists() && part.length() > before
                failures = if (advanced) 1 else failures + 1
                if (failures > 10) throw e
                Log.w("Porridge", "download of ${file.name} interrupted (${e.message}), retry $failures")
                delay(minOf(30_000L, 2_000L * failures))
            }
        }
    }

    private suspend fun fetch(file: ModelFile, part: File, progress: (Long) -> Unit) {
        val have = if (part.exists()) part.length() else 0L
        val request = Request.Builder().url(file.url).apply { if (have > 0) header("Range", "bytes=$have-") }.build()
        val client = Net.client.newBuilder().readTimeout(60, TimeUnit.SECONDS).callTimeout(0, TimeUnit.SECONDS).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Download failed (HTTP ${response.code}).")
            // 206: es geht weiter, wo es aufgehört hat; 200: der Server fängt von vorn an.
            val append = response.code == 206
            var done = if (append) have else 0L
            FileOutputStream(part, append).use { out ->
                response.body.byteStream().use { input ->
                    val buffer = ByteArray(256 * 1024)
                    var lastReport = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        done += n
                        if (done - lastReport > 2_000_000) { progress(done); lastReport = done }
                    }
                }
            }
            progress(done)
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

package de.letzgo.porridge.data

import android.content.Context
import android.os.Build
import android.util.Log
import de.letzgo.porridge.BuildConfig
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Ein lokales Protokoll für Abstürze und Reparaturen beim Start (nur Android). Es bleibt auf dem Gerät; der Nutzer kann
 * es in den Einstellungen kopieren oder teilen, wenn er einen Fehler meldet. Nichts wird von selbst übertragen.
 */
object CrashLog {
    private const val FILE = "crash-log.txt"
    /** Mehr hebt das Protokoll nicht auf: die jüngsten Einträge zählen. */
    private const val MAX_BYTES = 200_000

    @Volatile private var file: File? = null

    /** Ganz am Anfang des Starts: Ab hier landet jeder unbehandelte Absturz mit Stacktrace in der Datei. */
    fun install(context: Context) {
        file = File(context.filesDir, FILE)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching { write("Crash on thread ${thread.name}", error) }
            // Android beendet die App wie sonst auch (Dialog, Logcat).
            previous?.uncaughtException(thread, error)
        }
    }

    /** Hält etwas fest, das die App selbst abgefangen hat (eine reparierte Datenbank, ein verworfener Cache). */
    fun note(message: String, error: Throwable? = null) {
        Log.w("CrashLog", message, error)
        runCatching { write(message, error) }
    }

    fun read(): String? = file?.takeIf { it.exists() }?.let { runCatching { it.readText() }.getOrNull() }?.takeIf { it.isNotBlank() }

    fun clear() {
        file?.delete()
    }

    @Synchronized
    private fun write(message: String, error: Throwable?) {
        val target = file ?: return
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.US).format(Date())
        val entry = buildString {
            append("=== ").append(time).append(" · Porridge ").append(BuildConfig.VERSION_NAME).append(" (").append(BuildConfig.VERSION_CODE).append(")")
            append(" · Android ").append(Build.VERSION.RELEASE).append(" (API ").append(Build.VERSION.SDK_INT).append(") · ")
            append(Build.MANUFACTURER).append(' ').append(Build.MODEL).append('\n')
            append(message).append('\n')
            if (error != null) append(Log.getStackTraceString(error).ifEmpty { error.stackTraceToString() }).append('\n')
        }
        val old = if (target.exists()) target.readText() else ""
        val text = (old + entry).let { if (it.length > MAX_BYTES) it.takeLast(MAX_BYTES) else it }
        val temp = File(target.path + ".tmp")
        temp.writeText(text)
        temp.renameTo(target)
    }
}

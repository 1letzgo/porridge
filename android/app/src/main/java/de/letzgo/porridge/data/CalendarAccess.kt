package de.letzgo.porridge.data

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import java.util.Calendar

/** iOS: `CalendarAccess` (EventKit) — die Termine von heute, um eine Aufnahme nach einem zu benennen. */
object CalendarAccess {
    data class Appointment(val title: String, val start: Long, val end: Long, val allDay: Boolean)

    fun hasPermission(context: Context) = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun today(context: Context): List<Appointment> {
        if (!hasPermission(context)) return emptyList()
        val start = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
        val end = start + 24 * 3600_000L
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, start)
            ContentUris.appendId(it, end)
        }.build()
        val projection = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END, CalendarContract.Instances.ALL_DAY)
        val result = mutableListOf<Appointment>()
        context.contentResolver.query(uri, projection, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
            while (c.moveToNext()) {
                val title = c.getString(0)?.takeIf { it.isNotBlank() } ?: continue
                result += Appointment(title, c.getLong(1), c.getLong(2), c.getInt(3) == 1)
            }
        }
        return result
    }
}

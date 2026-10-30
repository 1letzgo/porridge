package de.letzgo.porridge.plaud

import android.util.Log

/** iOS: `PlaudLog` — Protokoll für die Fehlersuche (logcat statt Datei). */
object PlaudLog {
    fun log(s: String) { Log.i("PorridgePlaud", s) }
}

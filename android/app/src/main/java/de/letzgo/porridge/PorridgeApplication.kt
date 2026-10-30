package de.letzgo.porridge

import android.app.Application
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SecureStore
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase

/** iOS: PorridgeApp (App/PorridgeApp.swift) — einmalige Einrichtung beim Start. */
class PorridgeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        SecureStore.init(this)
        AudioStore.init(this)
        PorridgeDatabase.init(this)
    }
}

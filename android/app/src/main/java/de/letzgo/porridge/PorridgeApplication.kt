package de.letzgo.porridge

import android.app.Application
import de.letzgo.porridge.audio.RecordingSession
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SecureStore
import de.letzgo.porridge.ml.LocalLLM
import de.letzgo.porridge.ml.LocalModel
import de.letzgo.porridge.ml.ModelManager
import de.letzgo.porridge.ml.SentenceEmbedders
import de.letzgo.porridge.ml.TextEmbedder
import de.letzgo.porridge.ml.TextModels
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase

/** iOS: `PorridgeApp` (App/PorridgeApp.swift) — einmalige Einrichtung beim Start. */
class PorridgeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        SecureStore.init(this)
        AudioStore.init(this)
        PorridgeDatabase.init(this)
        ModelManager.init(this)
        // Ohne gespeicherte Wahl das Modell, das zum Arbeitsspeicher passt.
        if (Prefs.string(Keys.LOCAL_MODEL) == null || !hasChosenModel()) Prefs.set(Keys.LOCAL_MODEL, LocalModel.recommended(this).raw)
        selectLocalModel()
        SentenceEmbedders.current = TextEmbedder
        RecordingSession.init(this)
        ProcessingService.onBusyChanged = { RecordingSession.setBusy(it) }
    }

    private fun hasChosenModel() = getSharedPreferences("porridge", MODE_PRIVATE).contains(Keys.LOCAL_MODEL)

    companion object {
        fun selectLocalModel() {
            TextModels.selected = LocalLLM.of(LocalModel.of(Prefs.string(Keys.LOCAL_MODEL)))
        }
    }
}

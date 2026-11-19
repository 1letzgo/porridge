package de.letzgo.porridge

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import de.letzgo.porridge.audio.RecordingSession
import de.letzgo.porridge.data.AttachmentText
import de.letzgo.porridge.data.CrashLog
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SecureStore
import de.letzgo.porridge.ml.LocalLLM
import de.letzgo.porridge.ml.LocalModel
import de.letzgo.porridge.ml.ModelManager
import de.letzgo.porridge.audio.RecordingJournal
import de.letzgo.porridge.ml.TextModels
import kotlinx.coroutines.launch
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.sync.NextcloudSync

/** iOS: `PorridgeApp` (App/PorridgeApp.swift) — einmalige Einrichtung beim Start. */
class PorridgeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Zuerst: Was ab hier abstürzt, steht danach in den Einstellungen zum Teilen (Settings → Crash Log).
        CrashLog.install(this)
        Prefs.init(this)
        SecureStore.init(this)
        AudioStore.init(this)
        PorridgeDatabase.init(this)
        ModelManager.init(this)
        AttachmentText.init(this)
        // Ohne gespeicherte Wahl das Modell, das zum Arbeitsspeicher passt.
        optional("local model") {
            if (Prefs.string(Keys.LOCAL_MODEL) == null || !hasChosenModel()) Prefs.set(Keys.LOCAL_MODEL, LocalModel.recommended(this).raw)
            selectLocalModel()
        }
        // Das Modell der früheren Bedeutungssuche belegt sonst über 600 MB, ohne dass etwas es nutzt.
        optional("old embedding model") { java.io.File(ModelManager.root, "qwen3-embedding-0.6b").deleteRecursively() }
        RecordingSession.init(this)
        AppGraph.init(this)
        ProcessingService.onBusyChanged = { RecordingSession.setBusy(it) }
        // Der Abgleich ist eine Zusatzfunktion: Geht sein Start schief, läuft die App ohne ihn.
        optional("Nextcloud sync") { NextcloudSync.init(this) }
        AppGraph.scope.launch { optional("recording recovery") { RecordingJournal.recover() } }
        // Zurück in der App: holen, was die anderen Geräte getan haben.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = optional("sync on start") { NextcloudSync.syncSoon(0) }
            override fun onStop(owner: LifecycleOwner) = ModelManager.releaseIdleLLM()
        })
    }

    /** Ein Schritt, ohne den die App läuft: Scheitert er an Altbestand, wird das festgehalten statt abzustürzen. */
    private inline fun optional(what: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            CrashLog.note("Startup step \"$what\" failed and was skipped", e)
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_RUNNING_LOW) ModelManager.releaseIdleLLM()
    }

    private fun hasChosenModel() = getSharedPreferences("porridge", MODE_PRIVATE).contains(Keys.LOCAL_MODEL)

    companion object {
        fun selectLocalModel() {
            TextModels.selected = LocalLLM.of(LocalModel.of(Prefs.string(Keys.LOCAL_MODEL)))
        }
    }
}

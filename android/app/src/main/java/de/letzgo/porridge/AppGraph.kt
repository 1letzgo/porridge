package de.letzgo.porridge

import android.content.Context
import de.letzgo.porridge.index.NoteIndex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File

/** iOS: `AppContainer` und die Singletons (`NoteIndex.shared`) — was die Bildschirme gemeinsam brauchen. */
object AppGraph {
    /** Für Arbeit, die das Schließen eines Bildschirms überlebt: Speichern, Diktat, Zusammenfassung. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    lateinit var index: NoteIndex
        private set

    fun init(context: Context) {
        index = NoteIndex(File(context.filesDir, "Porridge/note-index.bin"))
    }
}

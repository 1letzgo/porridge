package de.letzgo.porridge

import android.content.Context
import de.letzgo.porridge.cloud.ChatStore
import de.letzgo.porridge.index.NoteIndex
import de.letzgo.porridge.ml.SentenceEmbedders
import java.io.File

/** iOS: `AppContainer` und die Singletons (`NoteIndex.shared`, `ChatStore`) — was die Bildschirme gemeinsam brauchen. */
object AppGraph {
    lateinit var index: NoteIndex
        private set
    lateinit var chat: ChatStore
        private set

    fun init(context: Context) {
        index = NoteIndex(File(context.filesDir, "Porridge/note-index.bin"), { SentenceEmbedders.current })
        chat = ChatStore(index)
    }
}

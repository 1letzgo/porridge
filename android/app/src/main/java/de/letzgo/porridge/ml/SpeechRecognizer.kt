package de.letzgo.porridge.ml

import de.letzgo.porridge.model.Word

/** Was die Audio-Seite (Live-Transkript, Diktat, Verarbeitung) von der Spracherkennung braucht. */
interface SpeechRecognizer {
    /** 16-kHz-Mono-Samples; liefert Wörter mit Zeiten (Sekunden ab Beginn der Samples). */
    suspend fun transcribe(samples: FloatArray, language: String?): List<Word>
}

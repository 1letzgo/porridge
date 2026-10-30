package de.letzgo.porridge.ml

/**
 * iOS: `TextEmbedder` — Satzvektoren (normiert, Kosinus = Skalarprodukt), um Passagen nach Bedeutung zu finden.
 * Die Umsetzung (ONNX-Modell über sherpa-onnx/onnxruntime) liegt in `ml/TextEmbedder.kt`; ohne Modell `null`.
 */
interface SentenceEmbedder {
    suspend fun isAvailable(): Boolean
    suspend fun vector(text: String): FloatArray?
}

object SentenceEmbedders {
    @Volatile var current: SentenceEmbedder? = null
}

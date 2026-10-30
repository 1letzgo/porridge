package de.letzgo.porridge.ml

/**
 * Das lokale Sprachmodell, wie Zusammenfassung und Chat es brauchen (iOS: `LocalLLM` + `ModelManager.ensureLLM`).
 * Die Umsetzung mit llama.cpp liegt in `ml/LocalLLM.kt`; Tests nutzen eine Attrappe.
 */
interface TextModel {
    /** Anzeigename, z. B. „Qwen3 4B“. */
    val displayName: String
    val isInstalled: Boolean
    /** Lädt herunter (falls nötig) und lädt in den Speicher; `progress` 0…1. */
    suspend fun ensureReady(progress: (Float) -> Unit)
    suspend fun generate(system: String, user: String, maxTokens: Int): String
    /** Gibt den Speicher frei, sobald niemand das Modell mehr braucht. */
    fun beginUse()
    fun endUse()
}

/** Wo die App ihr lokales Modell findet; `ml/LocalLLM.kt` setzt es beim Start. */
object TextModels {
    @Volatile var selected: TextModel? = null
}

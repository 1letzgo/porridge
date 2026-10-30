package de.letzgo.porridge.cloud

import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SummaryBilling
import de.letzgo.porridge.logic.SummaryException
import de.letzgo.porridge.logic.SummaryLogic
import de.letzgo.porridge.ml.TextModel
import de.letzgo.porridge.ml.TextModels
import de.letzgo.porridge.model.Note

/**
 * iOS: `SummaryService` (Services/SummaryService.swift) — fasst eine Notiz zusammen: lokal (Teile verdichten, bis alles
 * in einen Durchgang passt) oder beim Cloud-Anbieter mit eigenem Schlüssel. Liefert die geänderte Notiz; Speichern
 * und Aufgaben-Abgleich macht der Aufrufer (`processing/`).
 */
object SummaryService {
    /** Ob eine Zusammenfassung von selbst starten darf: das lokale Modell ist da, oder ein Schlüssel ist gesetzt. */
    val canRunWithoutAsking: Boolean
        get() = when (Prefs.billing) {
            SummaryBilling.LOCAL -> TextModels.selected?.isInstalled == true
            SummaryBilling.BYOK -> AIProvider.current.let { !it.requiresKey || it.apiKey.isNotEmpty() }
        }

    suspend fun summarize(note: Note, progress: (String) -> Unit = {}): Note {
        val request = SummaryLogic.request(note, Prefs.language)
        val (raw, model) = when (Prefs.billing) {
            SummaryBilling.LOCAL -> {
                val local = TextModels.selected ?: throw SummaryException("No on-device model is available.")
                summarizeLocally(local, request, progress) to "${local.displayName} (on-device)"
            }
            SummaryBilling.BYOK -> {
                val provider = AIProvider.current
                val key = provider.apiKey
                if (provider.requiresKey && key.isEmpty()) throw SummaryException.missingAPIKey(provider.label)
                progress("Writing summary …")
                CloudLLM.complete(provider, key, provider.model, request.system, request.user()) to "${provider.label} · ${provider.model}"
            }
        }
        return SummaryLogic.apply(note, raw, model, request.hasTranscript)
    }

    internal suspend fun summarizeLocally(model: TextModel, request: SummaryLogic.Request, progress: (String) -> Unit): String {
        model.beginUse()
        try {
            val installed = model.isInstalled
            progress(if (installed) "Loading model …" else "Downloading model …")
            model.ensureReady { fraction ->
                progress(if (!installed && fraction < 1) "Downloading model … ${(fraction * 100).toInt()} %" else "Loading model …")
            }
            var material = request.material
            var isNotes = false
            // Lange Meetings: jeden Teil zu Notizen verdichten, bis alles in einen Durchgang passt.
            while (material.length > SummaryLogic.SINGLE_PASS_LIMIT) {
                val parts = SummaryLogic.split(material)
                val notes = parts.mapIndexed { index, part ->
                    progress("Reading part ${index + 1} of ${parts.size} …")
                    model.generate(SummaryLogic.notesPrompt(request.language, request.noun), "Part ${index + 1} of ${parts.size}:\n\n$part", 700)
                }
                material = notes.joinToString("\n\n")
                isNotes = true
                if (parts.size == 1) break
            }
            progress("Writing summary …")
            val intro = if (isNotes) "Notes on the ${request.noun}, in order:" else request.intro
            return model.generate(request.system, request.user(material, intro), 1500)
        } finally {
            model.endUse()
        }
    }
}

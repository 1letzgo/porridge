package de.letzgo.porridge.cloud

import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SummaryBilling
import de.letzgo.porridge.logic.SummaryException
import de.letzgo.porridge.logic.SummaryLogic
import de.letzgo.porridge.logic.SummaryTemplate
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

    /** Das Modell der nächsten Zusammenfassung, so benannt wie neben einer fertigen. */
    val modelLabel: String?
        get() = when (Prefs.billing) {
            SummaryBilling.LOCAL -> TextModels.selected?.let { "${it.displayName} (on-device)" }
            SummaryBilling.BYOK -> "${AIProvider.current.label} · ${AIProvider.current.model}"
        }

    /** [model] gilt nur für diese Zusammenfassung; `null` ist der Standard. */
    suspend fun summarize(note: Note, template: SummaryTemplate = SummaryTemplate.GENERAL, model: SummaryModel? = null, progress: (String) -> Unit = {}): Note {
        // Eine Notiz im Eingang bekommt mit der Zusammenfassung einen Bucket vorgeschlagen.
        val buckets = de.letzgo.porridge.logic.InboxLogic.candidates(note, runCatching { de.letzgo.porridge.store.PorridgeDatabase.shared.folders().all() }.getOrDefault(emptyList()))
        val request = SummaryLogic.request(note, Prefs.language, de.letzgo.porridge.data.Me.name, template, buckets)
        val chosen = model ?: SummaryModel.current
        val raw = when (chosen) {
            is SummaryModel.Local -> {
                val local = if (model == null) TextModels.selected ?: throw SummaryException("No on-device model is available.") else de.letzgo.porridge.ml.LocalLLM.of(chosen.model)
                summarizeLocally(local, request, progress)
            }
            is SummaryModel.Cloud -> {
                val key = chosen.provider.apiKey
                if (chosen.provider.requiresKey && key.isEmpty()) throw SummaryException.missingAPIKey(chosen.provider.label)
                progress("Writing summary…")
                CloudLLM.complete(chosen.provider, key, chosen.modelId, request.system, request.user())
            }
        }
        return SummaryLogic.apply(note, raw, chosen.label, request.hasTranscript, buckets = buckets)
    }

    /**
     * iOS: `SummaryService.enhance` — schickt den Text einer einfachen Notiz zum Umschreiben und liefert die rohe
     * Antwort; `SummaryLogic.applyEnhance` legt sie auf die Notiz.
     */
    suspend fun enhance(text: String, model: SummaryModel? = null, progress: (String) -> Unit = {}): String {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) throw SummaryException.emptyNote
        val language = de.letzgo.porridge.logic.SummaryLanguage.detect(trimmed, Prefs.language)
        val system = SummaryLogic.enhancePrompt(language)
        val user = "Note:\n$trimmed\n\n${SummaryLogic.languageReminder(language)}"
        return when (val chosen = model ?: SummaryModel.current) {
            is SummaryModel.Local -> {
                // Die ganze Notiz muss in einen Durchgang passen: Teile kämen als Stichpunkte zurück, nicht als Notiz.
                if (trimmed.length > SummaryLogic.SINGLE_PASS_LIMIT) throw SummaryException.tooLongToEnhance
                val local = if (model == null) TextModels.selected ?: throw SummaryException("No on-device model is available.") else de.letzgo.porridge.ml.LocalLLM.of(chosen.model)
                local.beginUse()
                try {
                    val installed = local.isInstalled
                    progress(if (installed) "Loading model…" else "Downloading model…")
                    local.ensureReady { fraction ->
                        progress(if (!installed && fraction < 1) "Downloading model … ${(fraction * 100).toInt()} %" else "Loading model…")
                    }
                    progress("Enhancing note…")
                    local.generate(system, user, SummaryLogic.enhanceTokenLimit(trimmed))
                } finally {
                    local.endUse()
                }
            }
            is SummaryModel.Cloud -> {
                val key = chosen.provider.apiKey
                if (chosen.provider.requiresKey && key.isEmpty()) throw SummaryException.missingAPIKey(chosen.provider.label)
                progress("Enhancing note…")
                val answer = CloudLLM.completion(chosen.provider, key, chosen.modelId, system, user)
                if (answer.truncated) throw SummaryException.truncated
                answer.text
            }
        }
    }

    internal suspend fun summarizeLocally(model: TextModel, request: SummaryLogic.Request, progress: (String) -> Unit): String {
        model.beginUse()
        try {
            val installed = model.isInstalled
            progress(if (installed) "Loading model…" else "Downloading model…")
            model.ensureReady { fraction ->
                progress(if (!installed && fraction < 1) "Downloading model … ${(fraction * 100).toInt()} %" else "Loading model…")
            }
            var material = request.material
            var isNotes = false
            // Lange Meetings: jeden Teil zu Notizen verdichten, bis alles in einen Durchgang passt.
            while (material.length > SummaryLogic.SINGLE_PASS_LIMIT) {
                val parts = SummaryLogic.partPrompts(material, request.header)
                val notes = parts.mapIndexed { index, part ->
                    progress("Reading part ${index + 1} of ${parts.size}…")
                    model.generate(SummaryLogic.notesPrompt(request.language, request.noun, request.focus), part, 700)
                }
                material = notes.joinToString("\n\n")
                isNotes = true
                if (parts.size == 1) break
            }
            progress("Writing summary…")
            val intro = if (isNotes) "Notes on the ${request.noun}, in order:" else request.intro
            return model.generate(request.system, request.user(material, intro), 1500)
        } finally {
            model.endUse()
        }
    }
}

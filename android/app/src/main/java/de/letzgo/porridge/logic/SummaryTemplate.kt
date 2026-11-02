package de.letzgo.porridge.logic

import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * iOS: `SummaryTemplate` — worauf eine Meeting-Zusammenfassung achtet und welche Abschnitte sie hat. Sie beginnt immer
 * mit dem Zusammenfassungs-Abschnitt und endet mit Aufgaben und Tags, denn die liest die Aufgabenliste.
 */
@Serializable
data class SummaryTemplate(
    val id: String,
    val name: String,
    /** Wird dem Modell so gesagt; leer für eine einfache Zusammenfassung. */
    val focus: String,
    /** Die Abschnitte zwischen Zusammenfassung und Aufgaben, null für wichtige Punkte und Entscheidungen. */
    val sections: List<String>? = null,
) {
    companion object {
        val GENERAL = SummaryTemplate("general", "General", "")

        val BUILT_IN = listOf(
            GENERAL,
            SummaryTemplate(
                "oneOnOne", "One-on-One",
                "This is a one-on-one conversation. Pay attention to how the person is doing, feedback in both directions, goals and what was agreed.",
                listOf("Feedback", "Goals", "Agreements"),
            ),
            SummaryTemplate(
                "customer", "Customer Call",
                "This is a call with a customer. Pay attention to what the customer needs, objections and open questions, what was promised and the next steps.",
                listOf("Customer Needs", "Objections and Questions", "Commitments"),
            ),
            SummaryTemplate(
                "lecture", "Lecture",
                "This is a lecture or talk. Pay attention to the content: concepts, definitions, examples and how they connect, not to who said what.",
                listOf("Key Concepts", "Examples"),
            ),
        )

        private val serializer = ListSerializer(serializer())

        var custom: List<SummaryTemplate>
            get() = Prefs.string(Keys.CUSTOM_TEMPLATES)?.let { runCatching { Json.decodeFromString(serializer, it) }.getOrNull() }.orEmpty()
            set(value) = Prefs.set(Keys.CUSTOM_TEMPLATES, Json.encodeToString(serializer, value))

        val all: List<SummaryTemplate> get() = BUILT_IN + custom
    }
}

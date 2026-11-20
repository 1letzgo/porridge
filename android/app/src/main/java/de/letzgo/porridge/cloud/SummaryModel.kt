package de.letzgo.porridge.cloud

import de.letzgo.porridge.PorridgeApplication
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SummaryBilling
import de.letzgo.porridge.ml.LocalModel
import de.letzgo.porridge.ml.ModelManager
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * iOS: `SummaryModel` — ein Modell, das Zusammenfassungen schreibt, auf dem Gerät oder mit eigenem Schlüssel. Beide
 * werden gleich behandelt: eine Liste in den Einstellungen, ein Standard, eine Wahl bei jeder Meeting-Zusammenfassung.
 * Der Standard bleibt in den bisherigen Einstellungen (`BILLING`, `LOCAL_MODEL`, `PROVIDER`, `aiModel.…`).
 */
sealed interface SummaryModel {
    data class Local(val model: LocalModel) : SummaryModel
    data class Cloud(val provider: AIProvider, val modelId: String) : SummaryModel

    val name: String
        get() = when (this) {
            is Local -> model.displayName
            is Cloud -> provider.suggestedModels.firstOrNull { it.first == modelId }?.second ?: modelId
        }

    /** Wo es läuft. */
    val place: String
        get() = when (this) {
            is Local -> "On this device"
            is Cloud -> provider.label
        }

    /** iOS: `SummaryModel.id` — `local:<LocalModel>` oder `cloud:<AIProvider>:<Modell-ID>`. */
    val id: String
        get() = when (this) {
            is Local -> "local:${model.raw}"
            is Cloud -> "cloud:${provider.raw}:$modelId"
        }

    /** Kann jetzt antworten: ein lokales Modell, das da ist, oder ein Cloud-Modell mit Schlüssel (oder Serveradresse). */
    val isUsable: Boolean
        get() = when (this) {
            is Local -> ModelManager.isInstalled(model.pack)
            is Cloud -> if (provider == AIProvider.CUSTOM) AIProvider.customBaseURL.isNotEmpty() else (!provider.requiresKey || provider.apiKey.isNotEmpty())
        }

    val isLocal: Boolean get() = this is Local

    /** Was mit diesem Modell das Gerät verlässt, so gesagt wie in den Zusammenfassungs-Blättern; null auf dem Gerät. */
    fun sendsHint(material: String): String? =
        (this as? Cloud)?.let { "The $material goes to ${if (it.provider == AIProvider.CUSTOM) "your server" else it.provider.label}." }

    /** Im Menü, wo beides in eine Zeile muss. */
    val menuTitle: String get() = "$name · $place"

    /** So benannt wie neben einer fertigen Zusammenfassung. */
    val label: String
        get() = when (this) {
            is Local -> "${model.displayName} (on-device)"
            is Cloud -> "${provider.label} · $modelId"
        }

    @Serializable
    private data class Stored(val provider: String, val model: String)

    companion object {
        var current: SummaryModel
            get() = when (Prefs.billing) {
                SummaryBilling.LOCAL -> Local(LocalModel.of(Prefs.string(Keys.LOCAL_MODEL)))
                SummaryBilling.BYOK -> AIProvider.current.let { Cloud(it, it.model) }
            }
            set(value) {
                when (value) {
                    is Local -> {
                        Prefs.set(Keys.BILLING, SummaryBilling.LOCAL.raw)
                        Prefs.set(Keys.LOCAL_MODEL, value.model.raw)
                        PorridgeApplication.selectLocalModel()
                    }
                    is Cloud -> {
                        Prefs.set(Keys.BILLING, SummaryBilling.BYOK.raw)
                        AIProvider.current = value.provider
                        value.provider.model = value.modelId
                    }
                }
            }

        /**
         * iOS: `SummaryModel.chat` — das Modell, mit dem der Chat antwortet: das für den Chat gewählte („Chat Model“), oder
         * der Standard, wenn keins gewählt ist oder das gewählte weg ist (gelöscht, entfernt, sein Schlüssel genommen).
         * Nur auf diesem Gerät gespeichert. Zusammenfassungen nehmen immer den Standard.
         */
        val chat: SummaryModel
            get() = resolveChat(Prefs.string(Keys.CHAT_MODEL), available, { it.isUsable }, current)

        /** Das für den Chat gewählte Modell; null ist „Same as Default“. */
        var chatChoice: SummaryModel?
            get() {
                val stored = Prefs.string(Keys.CHAT_MODEL).orEmpty()
                return available.firstOrNull { it.id == stored }
            }
            set(value) = if (value != null) Prefs.set(Keys.CHAT_MODEL, value.id) else Prefs.remove(Keys.CHAT_MODEL)

        /** Das Modell des Chats aus dem Gespeicherten: das gewählte, wenn es in der Liste ist und laufen kann, sonst der Standard. */
        fun resolveChat(stored: String?, available: List<SummaryModel>, isUsable: (SummaryModel) -> Boolean, fallback: SummaryModel): SummaryModel {
            if (stored.isNullOrEmpty()) return fallback
            val chosen = available.firstOrNull { it.id == stored } ?: return fallback
            return if (isUsable(chosen)) chosen else fallback
        }

        internal fun encode(models: List<SummaryModel>): String = PorridgeJson.encodeToString(
            ListSerializer(Stored.serializer()),
            models.filterIsInstance<Cloud>().map { Stored(it.provider.raw, it.modelId) },
        )

        /** Ein unbekannter Anbieter fällt weg; `null`, wenn der Text nicht lesbar ist. */
        internal fun decode(text: String): List<SummaryModel>? = runCatching {
            PorridgeJson.decodeFromString(ListSerializer(Stored.serializer()), text).mapNotNull { item ->
                AIProvider.entries.firstOrNull { it.raw == item.provider }?.let { Cloud(it, item.model) }
            }
        }.getOrNull()

        /** Die hinzugefügten Cloud-Modelle dieses Geräts; Schlüssel gibt es je Anbieter. */
        var external: List<SummaryModel>
            get() = Prefs.string(Keys.EXTERNAL_MODELS)?.let(::decode) ?: carriedOver()
            set(value) = Prefs.set(Keys.EXTERNAL_MODELS, encode(value))

        /** Von vor der Liste: Jeder Dienst mit Schlüssel bringt sein gewähltes Modell mit, damit nichts verloren geht. */
        private fun carriedOver(): List<SummaryModel> {
            val models = AIProvider.entries.filter { provider ->
                provider.model.isNotEmpty() && if (provider == AIProvider.CUSTOM) AIProvider.customBaseURL.isNotEmpty() else provider.apiKey.isNotEmpty()
            }.map<AIProvider, SummaryModel> { Cloud(it, it.model) }.toMutableList()
            val chosen = current
            if (chosen is Cloud && chosen !in models) models.add(0, chosen)
            external = models
            return models
        }

        fun add(model: SummaryModel) {
            val models = external
            if (model is Cloud && model !in models) external = models + model
        }

        fun remove(model: SummaryModel) {
            external = external - model
            repairCurrent()
        }

        /** Was gewählt werden kann: was auf dem Gerät liegt oder hinzugefügt wurde. */
        val available: List<SummaryModel>
            get() = LocalModel.entries.filter { ModelManager.isInstalled(it.pack) }.map<LocalModel, SummaryModel> { Local(it) } + external

        /** Der Standard muss wählbar sein. Gibt es nichts, bleibt er: Ein lokales Modell lädt dann beim Benutzen. */
        fun repairCurrent() {
            val models = available
            if (models.isNotEmpty() && current !in models) current = models.first()
        }
    }
}

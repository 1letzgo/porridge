package de.letzgo.porridge.data

import kotlinx.serialization.json.Json

/** Ein JSON-Format für alles: unbekannte Felder (neuere iOS-Versionen, GitHub) stören nicht. */
val PorridgeJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

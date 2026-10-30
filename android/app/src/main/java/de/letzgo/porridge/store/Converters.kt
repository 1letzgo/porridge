package de.letzgo.porridge.store

import androidx.room.TypeConverter
import de.letzgo.porridge.data.PorridgeJson
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer

/** Listen als JSON-Text in einer Spalte (iOS: SwiftData speichert `[String]` ebenfalls am Stück). */
class Converters {
    private val strings = ListSerializer(String.serializer())

    @TypeConverter
    fun fromList(value: List<String>): String = PorridgeJson.encodeToString(strings, value)

    @TypeConverter
    fun toList(value: String): List<String> = runCatching { PorridgeJson.decodeFromString(strings, value) }.getOrDefault(emptyList())
}

package de.letzgo.porridge.sync

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.security.MessageDigest

/** Was das Gerät nach dem letzten Sync über einen Eintrag wusste: Hash der eigenen Fassung und Hash der Fassung in der Datei. */
@Serializable
data class SyncBase(val local: String, val remote: String)

/**
 * iOS: `SyncMerge` — Drei-Wege-Abgleich einer Sammlung (Notizen, Aufgaben, …) zwischen Gerät und Sync-Datei.
 * Was sich nur auf einer Seite geändert hat, gewinnt; geändert auf beiden: die neuere Änderung. Löschungen reisen als
 * Grabsteine (id → Zeitpunkt in ms).
 */
object SyncMerge {
    data class Local(val record: JsonObject, val updatedAt: Long)

    data class Result(
        /** Die Sammlung, wie sie zurück in die Datei geht. */
        val merged: Map<String, JsonObject>,
        /** Einträge, die ins Gerät geschrieben werden (neu oder anderswo geändert). */
        val toApply: Map<String, JsonObject>,
        /** Einträge des Geräts, die anderswo gelöscht wurden. */
        val toDelete: Set<String>,
        val tombstones: Map<String, Long>,
    )

    /** So lange bleiben Grabsteine, damit auch ein Gerät, das länger offline war, vom Löschen erfährt. */
    const val TOMBSTONE_AGE = 180L * 24 * 3600 * 1000

    /** [frozen]: Einträge, die diesmal unangetastet bleiben (eine Aufnahme, die noch verarbeitet wird). */
    fun merge(
        local: Map<String, Local>,
        remote: Map<String, JsonObject>,
        tombstones: Map<String, Long>,
        base: Map<String, SyncBase>,
        frozen: Set<String> = emptySet(),
        now: Long,
    ): Result {
        val merged = mutableMapOf<String, JsonObject>()
        val toApply = mutableMapOf<String, JsonObject>()
        val toDelete = mutableSetOf<String>()
        val stones = tombstones.filterValues { now - it < TOMBSTONE_AGE }.toMutableMap()
        for (id in local.keys + remote.keys + base.keys) {
            val l = local[id]
            val r = remote[id]
            val b = base[id]
            if (id in frozen) {
                if (r != null) merged[id] = r
                continue
            }
            val localDirty = l != null && (b == null || hash(l.record) != b.local)
            val remoteDirty = r != null && (b == null || hash(r) != b.remote)
            when {
                l == null && r == null -> Unit
                l != null && r == null -> {
                    val deletedAt = stones[id]
                    if (deletedAt != null) {
                        // Anderswo gelöscht; eine Änderung hier nach dem Löschen holt ihn zurück.
                        if (localDirty && l.updatedAt > deletedAt) {
                            stones.remove(id)
                            merged[id] = l.record
                        } else {
                            toDelete += id
                        }
                    } else {
                        merged[id] = l.record
                    }
                }
                l == null && r != null -> {
                    if (b != null && !remoteDirty) {
                        // Bekannt und hier verschwunden: auf diesem Gerät gelöscht.
                        stones[id] = now
                    } else {
                        merged[id] = r
                        toApply[id] = r
                        stones.remove(id)
                    }
                }
                else -> {
                    stones.remove(id)
                    val takeRemote = when {
                        !localDirty -> true
                        !remoteDirty -> false
                        else -> updatedAt(r!!) > l!!.updatedAt
                    }
                    if (takeRemote) {
                        merged[id] = r!!
                        if (remoteDirty) toApply[id] = r
                    } else {
                        merged[id] = l!!.record
                    }
                }
            }
        }
        return Result(merged, toApply, toDelete, stones)
    }

    /** Eine Einstellung in der Datei: ihr Wert ("" = keiner) und wann sie zuletzt geändert wurde (ms). */
    data class Setting(val value: String, val updatedAt: Long)

    data class SettingsResult(
        /** Werte, die ins Gerät geschrieben werden. */
        val toApply: Map<String, String>,
        /** Die Einstellungen, wie sie zurück in die Datei gehen (auch die der anderen Plattform). */
        val file: Map<String, Setting>,
        /** Die Werte als Grundlage des nächsten Laufs. */
        val base: Map<String, String>,
    )

    /**
     * iOS: `SyncMerge.mergeSettings` — Einstellungen, die dem Nutzer auf alle Geräte folgen (sein Name). Seit dem letzten
     * Lauf auf dem Gerät geändert: das Gerät gewinnt; sonst gilt die Datei. Beim ersten Lauf gewinnt ein Wert der Datei.
     * Nur die Schlüssel in [local] werden abgeglichen; die übrigen bleiben in der Datei, wie sie sind.
     */
    fun mergeSettings(local: Map<String, String>, remote: Map<String, Setting>, base: Map<String, String>, now: Long): SettingsResult {
        val toApply = mutableMapOf<String, String>()
        val file = remote.toMutableMap()
        val newBase = mutableMapOf<String, String>()
        for ((key, mine) in local) {
            val theirs = remote[key]
            val before = base[key]
            val localWins = if (before == null) theirs == null || (theirs.value.isEmpty() && mine.isNotEmpty()) else mine != before
            val value = if (localWins) mine else theirs?.value ?: mine
            if (localWins) {
                if (theirs?.value != mine && !(theirs == null && mine.isEmpty())) file[key] = Setting(mine, now)
            } else if (value != mine) {
                toApply[key] = value
            }
            newBase[key] = value
        }
        return SettingsResult(toApply, file, newBase)
    }

    fun updatedAt(record: JsonObject): Long =
        (record["updatedAt"] as? JsonPrimitive)?.longOrNull ?: (record["createdAt"] as? JsonPrimitive)?.longOrNull ?: 0

    /** Hash des kanonischen JSON (Schlüssel sortiert). */
    fun hash(record: JsonObject): String =
        MessageDigest.getInstance("SHA-256").digest(canonical(record).toByteArray()).joinToString("") { "%02x".format(it) }

    fun canonical(element: JsonElement): String = when (element) {
        is JsonObject -> element.keys.sorted().joinToString(",", "{", "}") { JsonPrimitive(it).toString() + ":" + canonical(element.getValue(it)) }
        is JsonArray -> element.joinToString(",", "[", "]") { canonical(it) }
        else -> element.toString()
    }
}

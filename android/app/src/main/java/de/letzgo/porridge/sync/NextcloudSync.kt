package de.letzgo.porridge.sync

import android.content.Context
import androidx.room.InvalidationTracker
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.VoiceProfile
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File

/** iOS: `SyncMode` — Android kennt nur aus oder Nextcloud. */
enum class SyncMode(val raw: String, val label: String) {
    OFF("off", "Off"),
    NEXTCLOUD("nextcloud", "Nextcloud");

    companion object {
        const val KEY = "syncMode"
        val chosen: SyncMode get() = entries.firstOrNull { it.raw == Prefs.string(KEY) } ?: OFF
    }
}

/**
 * iOS: `NextcloudSync` — Sync über eine Nextcloud: eine Datei `Porridge/porridge-sync.json` mit allen Notizen, Aufgaben,
 * Ordnern und Stimmen, die iPhone, Mac und Android gleich lesen, dazu die Aufnahmen in `Porridge/Recordings/`.
 *
 * Jeder Lauf liest die Datei, gleicht sie in drei Wegen mit dem Gerät ab ([SyncMerge]), schreibt das Ergebnis in die
 * Datenbank und legt die Datei nur zurück, wenn kein anderes Gerät dazwischen geschrieben hat (ETag); sonst von vorn.
 */
object NextcloudSync {
    data class Status(
        val account: NextcloudAccount? = null,
        val syncing: Boolean = false,
        val lastSync: Long? = null,
        val error: String? = null,
    )

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutex = Mutex()
    private var pending: Job? = null
    private lateinit var stateFile: File
    @Volatile private var ownWriteAt = 0L

    private const val FILE_NAME = "porridge-sync.json"
    private const val LAST_SYNC_KEY = "nextcloudLastSync"
    private val TABLES = arrayOf("notes", "action_items", "folders", "voice_profiles")

    val isActive: Boolean get() = SyncMode.chosen == SyncMode.NEXTCLOUD && _status.value.account != null

    /** Einmal beim Start: Stand laden, auf Änderungen in der Datenbank hören, ab und zu nachsehen. */
    fun init(context: Context) {
        stateFile = File(context.filesDir, "NextcloudSync/state.json")
        _status.value = Status(account = NextcloudAccount.saved, lastSync = Prefs.long(LAST_SYNC_KEY).takeIf { it > 0 })
        PorridgeDatabase.shared.invalidationTracker.addObserver(object : InvalidationTracker.Observer(TABLES) {
            override fun onInvalidated(tables: Set<String>) {
                // Nicht für das Schreiben eines Laufs selbst.
                if (!mutex.isLocked && System.currentTimeMillis() - ownWriteAt > 3000) syncSoon()
            }
        })
        scope.launch {
            while (true) {
                delay(300_000)
                syncSoon(0)
            }
        }
        syncSoon(1000)
    }

    fun connect(account: NextcloudAccount) {
        account.save()
        Prefs.set(SyncMode.KEY, SyncMode.NEXTCLOUD.raw)
        stateFile.delete()
        _status.value = Status(account = account)
        syncSoon(0)
    }

    fun disconnect() {
        NextcloudAccount.remove()
        stateFile.delete()
        Prefs.remove(LAST_SYNC_KEY)
        _status.value = Status()
    }

    /** Ein Sync gleich; Änderungen kurz nacheinander landen in einem Lauf. */
    fun syncSoon(delayMillis: Long = 4000) {
        if (!isActive) return
        pending?.cancel()
        pending = scope.launch {
            delay(delayMillis)
            sync()
        }
    }

    suspend fun sync() {
        val account = _status.value.account ?: return
        if (!isActive || mutex.isLocked) return
        mutex.withLock {
            _status.update { it.copy(syncing = true) }
            try {
                val dav = WebDAV(account)
                syncFile(dav)
                syncRecordings(dav)
                val now = System.currentTimeMillis()
                Prefs.set(LAST_SYNC_KEY, now)
                _status.update { it.copy(syncing = false, lastSync = now, error = null) }
            } catch (e: Exception) {
                _status.update { it.copy(syncing = false, error = e.message ?: e.toString()) }
            }
        }
    }

    // Die Datei

    /** Eine Sammlung der Datei: wie die Einträge zu JSON werden und zurück in die Datenbank. */
    private class Collection<T>(
        val key: String,
        val serializer: KSerializer<T>,
        val id: (T) -> String,
        val frozen: (T) -> Boolean = { false },
        val load: suspend () -> List<T>,
        val save: suspend (List<T>) -> Unit,
        val delete: suspend (List<T>) -> Unit,
    ) {
        suspend fun locals(): Pair<List<T>, Map<String, SyncMerge.Local>> {
            val all = load()
            return all to all.associate { model ->
                val record = PorridgeJson.encodeToJsonElement(serializer, model).jsonObject
                id(model) to SyncMerge.Local(record, SyncMerge.updatedAt(record))
            }
        }

        fun decode(record: JsonObject): T = PorridgeJson.decodeFromJsonElement(serializer, record)
    }

    private val collections: List<Collection<*>>
        get() {
            val db = PorridgeDatabase.shared
            return listOf(
                Collection(
                    "notes", Note.serializer(), { it.id }, frozen = ::isFrozen,
                    load = { db.notes().all() }, save = { db.notes().upsertAll(it) },
                    delete = { notes ->
                        notes.forEach { note ->
                            (listOfNotNull(note.audioFileName) + note.audioFileNames).forEach(AudioStore::delete)
                            db.notes().delete(note)
                        }
                    },
                ),
                Collection(
                    "actionItems", ActionItem.serializer(), { it.id },
                    load = { db.actionItems().all() }, save = { db.actionItems().upsertAll(it) }, delete = { it.forEach { item -> db.actionItems().delete(item) } },
                ),
                Collection(
                    "folders", NoteFolder.serializer(), { it.id },
                    load = { db.folders().all() }, save = { db.folders().upsertAll(it) }, delete = { db.folders().deleteAll(it.map { f -> f.id }) },
                ),
                // Stimmabdrücke stammen auf iOS aus einem anderen Modell: jede Plattform hat ihre eigene Liste.
                Collection(
                    "voiceProfilesAndroid", VoiceProfile.serializer(), { it.id },
                    load = { db.voiceProfiles().all() }, save = { db.voiceProfiles().upsertAll(it) }, delete = { it.forEach { p -> db.voiceProfiles().delete(p) } },
                ),
            )
        }

    /** Eine Aufnahme auf dem Weg zum Transkript bleibt auf dem Gerät, bis sie fertig ist. */
    fun isFrozen(note: Note) =
        note.pendingAudioFileName != null || note.status == ProcessingStatus.RECORDED || note.status == ProcessingStatus.TRANSCRIBING

    @Serializable
    private data class State(
        val base: Map<String, Map<String, SyncBase>> = emptyMap(),
        /** Die Einstellungen beim letzten Lauf (Schlüssel der Datei → Wert). */
        val settings: Map<String, String> = emptyMap(),
    )

    // Einstellungen, die dem Nutzer auf alle Geräte folgen: Schlüssel in der Datei → Schlüssel hier. Welche Stimme
    // seine ist, gilt nur je Plattform (die Stimmen von iPhone und Mac sind andere als die von Android).
    private val SETTINGS = mapOf(
        "myName" to Keys.MY_NAME,
        "myVoiceName" to Keys.MY_VOICE_NAME,
        "myVoiceAndroid" to Keys.MY_VOICE,
    )

    /** iOS: `NextcloudSync.mergeSettings` — gleicht die Einstellungen ab, schreibt Geändertes ins Gerät und in [output]. */
    private fun mergeSettings(file: JsonObject, output: MutableMap<String, JsonElement>, state: State): Map<String, String> {
        val remote = (file["settings"] as? JsonObject).orEmpty().mapNotNull { (key, element) ->
            val entry = element as? JsonObject ?: return@mapNotNull null
            val value = (entry["value"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return@mapNotNull null
            key to SyncMerge.Setting(value, (entry["updatedAt"] as? JsonPrimitive)?.longOrNull ?: 0)
        }.toMap()
        val local = SETTINGS.mapValues { Prefs.string(it.value).orEmpty() }
        val result = SyncMerge.mergeSettings(local, remote, state.settings, System.currentTimeMillis())
        for ((key, value) in result.toApply) SETTINGS[key]?.let { Prefs.set(it, value.ifEmpty { null }) }
        if (result.file.isNotEmpty() || "settings" in file) {
            output["settings"] = JsonObject(result.file.mapValues { (_, setting) ->
                JsonObject(mapOf("value" to JsonPrimitive(setting.value), "updatedAt" to JsonPrimitive(setting.updatedAt)))
            })
        }
        return result.base
    }

    private fun loadState(): State =
        runCatching { PorridgeJson.decodeFromString(State.serializer(), stateFile.readText()) }.getOrDefault(State())

    private fun saveState(state: State) {
        stateFile.parentFile?.mkdirs()
        stateFile.writeText(PorridgeJson.encodeToString(State.serializer(), state))
    }

    private suspend fun syncFile(dav: WebDAV) {
        val url = dav.file(dav.root, FILE_NAME)
        val state = loadState()
        repeat(4) { attempt ->
            val remote = dav.get(url)
            if (remote == null && attempt == 0) dav.makeFolder(dav.root)
            val file = remote?.let { runCatching { PorridgeJson.parseToJsonElement(it.data.decodeToString()).jsonObject }.getOrNull() } ?: JsonObject(emptyMap())
            val tombstones = file["deleted"] as? JsonObject
            val output = file.toMutableMap()
            output["version"] = JsonPrimitive(1)
            val deleted = mutableMapOf<String, JsonElement>()
            val newBase = mutableMapOf<String, MutableMap<String, SyncBase>>()
            ownWriteAt = System.currentTimeMillis()
            for (collection in collections) {
                val result = mergeCollection(collection, file, tombstones, state)
                output[collection.key] = JsonArray(result.merged.keys.sorted().map { result.merged.getValue(it) })
                deleted[collection.key] = JsonObject(result.tombstones.mapValues { JsonPrimitive(it.value) })
                newBase[collection.key] = result.merged.mapValues { SyncBase("", SyncMerge.hash(it.value)) }.toMutableMap()
            }
            ownWriteAt = System.currentTimeMillis()
            output["deleted"] = JsonObject(deleted)
            val settingsBase = mergeSettings(file, output, state)

            val data = SyncMerge.canonical(JsonObject(output))
            val before = remote?.let { SyncMerge.canonical(file) }
            try {
                if (data != before) dav.put(data.toByteArray(), url, remote?.etag)
            } catch (_: SyncConflict) {
                return@repeat
            }
            // Erst jetzt, mit geschriebener Datei, wird der Stand zur Grundlage des nächsten Laufs.
            for (collection in collections) {
                val base = newBase.getValue(collection.key)
                for ((id, local) in collection.locals().second) {
                    base[id]?.let { base[id] = it.copy(local = SyncMerge.hash(local.record)) }
                }
            }
            saveState(State(newBase, settingsBase))
            return
        }
        throw SyncConflict()
    }

    private suspend fun <T> mergeCollection(collection: Collection<T>, file: JsonObject, tombstones: JsonObject?, state: State): SyncMerge.Result {
        val (models, locals) = collection.locals()
        val remote = (file[collection.key] as? JsonArray).orEmpty().mapNotNull { element ->
            val record = element as? JsonObject ?: return@mapNotNull null
            val id = record["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            id to record
        }.toMap()
        val stones = (tombstones?.get(collection.key) as? JsonObject).orEmpty().mapNotNull { (id, value) ->
            (value as? JsonPrimitive)?.longOrNull?.let { id to it }
        }.toMap()
        val result = SyncMerge.merge(
            local = locals,
            remote = remote,
            tombstones = stones,
            base = state.base[collection.key].orEmpty(),
            frozen = models.filter(collection.frozen).map(collection.id).toSet(),
            now = System.currentTimeMillis(),
        )
        val applied = result.toApply.values.mapNotNull { runCatching { collection.decode(it) }.getOrNull() }
        if (applied.isNotEmpty()) collection.save(applied)
        val gone = models.filter { collection.id(it) in result.toDelete }
        if (gone.isNotEmpty()) collection.delete(gone)
        return result
    }

    // Aufnahmen

    /** Aufnahmen, die das Gerät hat, gehen hoch; fehlende Aufnahmen synchronisierter Notizen kommen herunter. */
    private suspend fun syncRecordings(dav: WebDAV) {
        val notes = PorridgeDatabase.shared.notes().all().filterNot(::isFrozen)
        val wanted = notes.flatMap { listOfNotNull(it.audioFileName) + it.audioFileNames }.toSet()
        if (wanted.isEmpty()) return
        val remote = dav.list(dav.recordings).toMutableSet()
        if (remote.isEmpty()) dav.makeFolder(dav.recordings)
        // Nur Dateinamen, nie Pfade, aus der Datei eines anderen Geräts.
        for (name in wanted.sorted().filter { it.isNotEmpty() && '/' !in it && !it.startsWith(".") }) {
            val target = dav.file(dav.recordings, name)
            if (AudioStore.exists(name) && name !in remote) {
                dav.upload(AudioStore.file(name), target)
                remote += name
            } else if (!AudioStore.exists(name) && name in remote) {
                dav.download(target, AudioStore.file(name))
            }
        }
    }
}


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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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
    /** Jemand wollte einen Sync, während einer lief: Es folgt ein weiterer. */
    @Volatile private var syncAgain = false
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
                if (System.currentTimeMillis() - ownWriteAt > 3000) syncSoon()
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
            // Ein neuer Anlass ersetzt nur das Warten, nie einen laufenden Sync.
            withContext(NonCancellable) { sync() }
        }
    }

    suspend fun sync() {
        val account = _status.value.account ?: return
        if (!isActive) return
        if (mutex.isLocked) {
            syncAgain = true
            return
        }
        mutex.withLock {
            _status.update { it.copy(syncing = true) }
            try {
                val dav = WebDAV(account)
                val unreadable = syncFile(dav)
                syncRecordings(dav)
                val now = System.currentTimeMillis()
                Prefs.set(LAST_SYNC_KEY, now)
                val error = if (unreadable > 0) "$unreadable synced entries could not be read. Update the app on this device." else null
                _status.update { it.copy(syncing = false, lastSync = now, error = error) }
            } catch (e: CancellationException) {
                _status.update { it.copy(syncing = false) }
                throw e
            } catch (e: Exception) {
                _status.update { it.copy(syncing = false, error = e.message ?: e.toString()) }
            }
        }
        if (syncAgain) {
            syncAgain = false
            syncSoon()
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
                val record = record(model)
                id(model) to SyncMerge.Local(record, SyncMerge.updatedAt(record))
            }
        }

        fun record(model: T): JsonObject = PorridgeJson.encodeToJsonElement(serializer, model).jsonObject

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
        /** Aufnahmen, auf die die Datei beim letzten Lauf zeigte; null vor dem ersten Lauf mit dieser Liste. */
        val recordings: List<String>? = null,
        /** Aufnahmen, auf die nichts mehr zeigt: gehen auf dem Server und hier weg. */
        val orphans: List<String> = emptyList(),
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

    /** Gibt zurück, wie viele Einträge der Datei dieses Gerät nicht lesen konnte. */
    private suspend fun syncFile(dav: WebDAV): Int {
        val url = dav.file(dav.root, FILE_NAME)
        val state = loadState()
        repeat(4) { attempt ->
            val remote = dav.get(url)
            if (remote == null && attempt == 0) dav.makeFolder(dav.root)
            val file = remote?.let { SyncMerge.parseFile(it.data.decodeToString()) } ?: JsonObject(emptyMap())
            val tombstones = file["deleted"] as? JsonObject
            val output = file.toMutableMap()
            output["version"] = JsonPrimitive(1)
            // Beginnt mit der Datei: Die Stimmen der anderen Plattform haben eigene Tombstones.
            val deleted = tombstones.orEmpty().toMutableMap()
            var unreadable = 0
            val newBase = mutableMapOf<String, MutableMap<String, SyncBase>>()
            ownWriteAt = System.currentTimeMillis()
            for (collection in collections) {
                val merge = mergeCollection(collection, file, tombstones, state)
                val result = merge.result
                unreadable += merge.unreadable.size
                output[collection.key] = JsonArray(result.merged.keys.sorted().map { result.merged.getValue(it) })
                deleted[collection.key] = JsonObject(result.tombstones.mapValues { JsonPrimitive(it.value) })
                // Ein nicht lesbarer Eintrag bleibt in der Datei, aber ohne Grundlage: Sonst läse ihn der nächste
                // Lauf als „hier gelöscht“, und er verschwände auf allen Geräten.
                newBase[collection.key] = result.merged.filterKeys { it !in merge.unreadable }
                    .mapValues { (id, record) -> SyncBase(merge.localHashes[id].orEmpty(), SyncMerge.hash(record)) }.toMutableMap()
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
            val referenced = referencedRecordings(output["notes"] as? JsonArray)
            val released = state.recordings.orEmpty() - referenced
            saveState(State(newBase, settingsBase, referenced.sorted(), (state.orphans + released).distinct() - referenced))
            return unreadable
        }
        throw SyncConflict()
    }

    /**
     * [localHashes]: der Stand, den dieser Lauf gesehen oder selbst geschrieben hat, nicht ein späteres Nachlesen.
     * Was der Nutzer danach ändert, gilt so im nächsten Lauf als geändert und geht hoch.
     */
    private class CollectionMerge(val result: SyncMerge.Result, val localHashes: Map<String, String>, val unreadable: Set<String>)

    private suspend fun <T> mergeCollection(collection: Collection<T>, file: JsonObject, tombstones: JsonObject?, state: State): CollectionMerge {
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
        val localHashes = locals.mapValues { SyncMerge.hash(it.value.record) }.toMutableMap()
        val unreadable = mutableSetOf<String>()
        val applied = result.toApply.mapNotNull { (id, record) ->
            runCatching { collection.decode(record) }
                .onSuccess { localHashes[id] = SyncMerge.hash(collection.record(it)) }
                .onFailure { unreadable += id }
                .getOrNull()
        }
        if (applied.isNotEmpty()) collection.save(applied)
        val gone = models.filter { collection.id(it) in result.toDelete }
        if (gone.isNotEmpty()) collection.delete(gone)
        return CollectionMerge(result, localHashes, unreadable)
    }

    // Aufnahmen

    /** Die Aufnahmen der Notizen in der Datei und der hiesigen, die noch verarbeitet werden. */
    private suspend fun referencedRecordings(notes: JsonArray?): Set<String> {
        val inFile = notes.orEmpty().flatMap { element ->
            val record = element as? JsonObject ?: return@flatMap emptyList()
            listOfNotNull((record["audioFileName"] as? JsonPrimitive)?.takeIf { it.isString }?.content) +
                (record["audioFileNames"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        }
        val frozen = PorridgeDatabase.shared.notes().all().filter(::isFrozen)
            .flatMap { listOfNotNull(it.audioFileName, it.pendingAudioFileName) + it.audioFileNames }
        return (inFile + frozen).toSet()
    }

    /** Aufnahmen, die das Gerät hat, gehen hoch; fehlende Aufnahmen synchronisierter Notizen kommen herunter. */
    private suspend fun syncRecordings(dav: WebDAV) {
        val all = PorridgeDatabase.shared.notes().all()
        val notes = all.filterNot(::isFrozen)
        val wanted = notes.flatMap { listOfNotNull(it.audioFileName) + it.audioFileNames }.toSet()
        val state = loadState()
        if (wanted.isEmpty() && state.orphans.isEmpty()) return
        val remote = dav.list(dav.recordings).toMutableSet()
        // Aufnahmen, die irgendwo gelöscht wurden: weg vom Server, und hier, wenn keine Notiz mehr darauf zeigt.
        if (state.orphans.isNotEmpty()) {
            val inUse = all.flatMap { listOfNotNull(it.audioFileName, it.pendingAudioFileName) + it.audioFileNames }.toSet()
            for (name in state.orphans.filter(AudioStore::isPlainName)) {
                if (name in remote) dav.delete(dav.file(dav.recordings, name))
                remote -= name
                if (name !in inUse) AudioStore.delete(name)
            }
            saveState(loadState().copy(orphans = emptyList()))
        }
        if (wanted.isEmpty()) return
        if (remote.isEmpty()) dav.makeFolder(dav.recordings)
        for (name in wanted.sorted().filter(AudioStore::isPlainName)) {
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

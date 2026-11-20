package de.letzgo.porridge.sync

import android.content.Context
import androidx.room.InvalidationTracker
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.model.Attachment
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
import kotlinx.serialization.builtins.ListSerializer
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
    @Volatile private var pending: Job? = null
    /** Jemand wollte einen Sync, während einer lief: Es folgt ein weiterer. */
    private val syncAgain = java.util.concurrent.atomic.AtomicBoolean(false)
    private lateinit var stateFile: File
    private lateinit var connectivity: android.net.ConnectivityManager
    /**
     * Wann ein Lauf zuletzt selbst in die Datenbank schrieb. Gesetzt nur, wenn er wirklich schreibt: Ein Lauf, der nichts
     * übernimmt (die meisten), schluckt so keine Änderung, die der Nutzer kurz danach macht.
     */
    @Volatile private var ownWriteAt = 0L
    /**
     * iOS: `NextcloudSync.generation` — zählt Verbinden und Trennen: Ein Lauf, der sieht, dass sie sich geändert hat,
     * während er wartete, war für ein anderes Konto und lässt Stand, Konto und Uploads in Ruhe.
     */
    private val generation = java.util.concurrent.atomic.AtomicInteger(0)

    /** Ein Lauf, dessen Konto verbunden oder getrennt wurde, während er wartete (iOS: `CancellationError` aus `checkAccount`). */
    private class AccountChanged : CancellationException("Nextcloud account changed during the sync")

    private const val FILE_NAME = "porridge-sync.json"
    private const val LAST_SYNC_KEY = "nextcloudLastSync"
    private val TABLES = arrayOf("notes", "folders", "voice_profiles")

    val isActive: Boolean get() = SyncMode.chosen == SyncMode.NEXTCLOUD && _status.value.account != null

    /** Einmal beim Start: Stand laden, auf Änderungen in der Datenbank hören, ab und zu nachsehen. */
    fun init(context: Context) {
        stateFile = File(context.filesDir, "NextcloudSync/state.json")
        resetIfDatabaseRebuilt(context)
        connectivity = context.getSystemService(android.net.ConnectivityManager::class.java)
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

    // Erst das neue Konto im Status, dann die Generation: Ein Lauf liest die Generation vor dem Konto und sieht so nie
    // die neue Generation mit dem alten Konto.
    fun connect(account: NextcloudAccount) {
        account.save()
        Prefs.set(SyncMode.KEY, SyncMode.NEXTCLOUD.raw)
        stateFile.delete()
        _status.value = Status(account = account)
        generation.incrementAndGet()
        syncSoon(0)
    }

    fun disconnect() {
        NextcloudAccount.remove()
        stateFile.delete()
        Prefs.remove(LAST_SYNC_KEY)
        _status.value = Status()
        generation.incrementAndGet()
    }

    /** iOS: `NextcloudSync.checkAccount` — hält einen Lauf an, dessen Konto verbunden oder getrennt wurde, während er wartete. */
    private fun checkAccount(run: Int) {
        if (run != generation.get()) throw AccountChanged()
    }

    /**
     * Wurde die Datenbank seit dem letzten Lauf neu aufgebaut (`DatabaseRepair`, im schlimmsten Fall leer), gilt der
     * gespeicherte Stand nicht mehr: Mit ihm hielte der nächste Lauf jede fehlende Notiz für hier gelöscht und löschte sie
     * auf allen Geräten (iOS: kein `attach` bei `AppContainer.storeError`). Ohne Stand kommt alles aus der Datei zurück.
     */
    private fun resetIfDatabaseRebuilt(context: Context) {
        val folder = context.getDatabasePath(PorridgeDatabase.FILE_NAME).parentFile ?: return
        val prefix = PorridgeDatabase.FILE_NAME + ".backup-"
        val rebuiltAt = folder.listFiles().orEmpty().mapNotNull { file ->
            file.name.takeIf { it.startsWith(prefix) }?.removePrefix(prefix)?.takeWhile(Char::isDigit)?.toLongOrNull()
        }.maxOrNull() ?: return
        if (stateFile.exists() && rebuiltAt >= stateFile.lastModified()) {
            de.letzgo.porridge.data.CrashLog.note("The database was rebuilt; the Nextcloud sync starts over without its last state.")
            stateFile.delete()
        }
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
        if (_status.value.account == null || !isActive) return
        if (mutex.isLocked) {
            syncAgain.set(true)
            // Der laufende Sync kann gerade fertig geworden sein und die Marke nicht mehr gesehen haben.
            if (!mutex.isLocked && syncAgain.compareAndSet(true, false)) syncSoon()
            return
        }
        mutex.withLock {
            // Die Generation vor dem Konto (siehe `connect`).
            val run = generation.get()
            var account = _status.value.account ?: return@withLock
            _status.update { it.copy(syncing = true) }
            try {
                if (account.userID == null) {
                    WebDAV(account).fetchUserID()?.let { id ->
                        checkAccount(run)
                        account = account.copy(userID = id)
                        account.save()
                        _status.update { if (it.account?.loginName == account.loginName) it.copy(account = account) else it }
                    }
                }
                val dav = WebDAV(account)
                val unreadable = syncFile(dav, run)
                syncRecordings(dav, run)
                checkAccount(run)
                val now = System.currentTimeMillis()
                Prefs.set(LAST_SYNC_KEY, now)
                val error = if (unreadable > 0) "$unreadable synced entries could not be read. Update the app on this device." else null
                _status.update { it.copy(syncing = false, lastSync = now, error = error) }
            } catch (_: AccountChanged) {
                // Verbunden oder getrennt: Der neue Status gehört dem neuen Konto, dieser Lauf hinterlässt nichts darin.
                _status.update { it.copy(syncing = false) }
            } catch (e: CancellationException) {
                _status.update { it.copy(syncing = false) }
                throw e
            } catch (e: Exception) {
                // Der Fehler dieses Laufs ist nicht der des neuen Kontos.
                _status.update { if (run == generation.get()) it.copy(syncing = false, error = e.message ?: e.toString()) else it.copy(syncing = false) }
            }
        }
        if (syncAgain.compareAndSet(true, false)) syncSoon()
    }

    // Die Datei

    /** Eine Sammlung der Datei: wie die Einträge zu JSON werden und zurück in die Datenbank. */
    private class Collection<T>(
        val key: String,
        val serializer: KSerializer<T>,
        val id: (T) -> String,
        /** Felder, die nur auf diesem Gerät gelten und nie in die Datei gehen. */
        val localOnly: Set<String> = emptySet(),
        val frozen: (T) -> Boolean = { false },
        val load: suspend () -> List<T>,
        val save: suspend (List<T>) -> Unit,
        val delete: suspend (List<T>) -> Unit,
        /** Was von einem Eintrag gilt, der hier schon liegt: der gelesene Eintrag, sein JSON und der hiesige Stand. */
        val adopt: (decoded: T, record: JsonObject, local: T?) -> T = { decoded, _, _ -> decoded },
    ) {
        suspend fun locals(): Pair<List<T>, Map<String, SyncMerge.Local>> {
            val all = load()
            return all to all.associate { model ->
                val record = record(model)
                id(model) to SyncMerge.Local(record, SyncMerge.updatedAt(record))
            }
        }

        fun record(model: T): JsonObject {
            val record = PorridgeJson.encodeToJsonElement(serializer, model).jsonObject
            return if (localOnly.none { it in record }) record else JsonObject(record - localOnly)
        }

        fun decode(record: JsonObject): T = PorridgeJson.decodeFromJsonElement(serializer, record)
    }

    private val collections: List<Collection<*>>
        get() {
            val db = PorridgeDatabase.shared
            return listOf(
                Collection(
                    "notes", Note.serializer(), { it.id }, frozen = ::isFrozen,
                    // iOS: `SyncRecords.record` — der Teil, der auf „Try Again“ wartet, wird nie hochgeladen: Auf einem
                    // anderen Gerät zeigte er ins Leere (und hielte dort das Weiterführen des Meetings auf).
                    localOnly = NOTE_LOCAL_ONLY,
                    load = { db.notes().all() }, save = { db.notes().upsertAll(it) },
                    delete = { notes ->
                        notes.forEach { note ->
                            // Die Dateien erst, wenn die Notiz wirklich aus der Datenbank ist.
                            db.notes().delete(note)
                            note.storedFileNames.forEach(AudioStore::delete)
                        }
                    },
                    // iOS: `SyncRecords.apply` — ein Eintrag einer Version von vor dem Eingang kennt dessen Felder nicht (neuere
                    // schreiben `sourceRaw` immer): Was dieses Gerät weiß, bleibt.
                    // Ebenso die To-do-Felder (`SyncMerge.adoptNote`).
                    adopt = SyncMerge::adoptNote,
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

    /** Felder einer Notiz, die nicht in die Datei gehen (iOS: `SyncRecords.record`). */
    internal val NOTE_LOCAL_ONLY = setOf("pendingAudioFileName")

    /** iOS: `SyncRecords.record` — der Eintrag einer Notiz, wie er in die Datei geht (wie die Sammlung „notes“ ihn bildet). */
    internal fun noteRecord(note: Note): JsonObject =
        JsonObject(PorridgeJson.encodeToJsonElement(Note.serializer(), note).jsonObject - NOTE_LOCAL_ONLY)

    /**
     * iOS: `SyncRecords.isFrozen` — eine Aufnahme auf dem Weg zum Transkript bleibt auf dem Gerät, bis sie fertig ist. Eine,
     * die scheiterte (`FAILED`, ihr Teil noch in `pendingAudioFileName` für „Try Again“), wird wieder abgeglichen: Eingefroren
     * bliebe sie für immer draußen. Ihr Teil bleibt hier ([NOTE_LOCAL_ONLY], `SyncMerge.adoptNote`).
     */
    fun isFrozen(note: Note) =
        note.status == ProcessingStatus.RECORDED || note.status == ProcessingStatus.TRANSCRIBING

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

    /** Ein Netz mit Volumengrenze wartet, wenn es so eingestellt ist. Hochgeladen wird dann beim nächsten Lauf im WLAN. */
    private fun uploadsAllowed(): Boolean = !Prefs.bool(Keys.RECORDINGS_WIFI_ONLY) || !connectivity.isActiveNetworkMetered

    private fun loadState(): State =
        runCatching { PorridgeJson.decodeFromString(State.serializer(), stateFile.readText()) }.getOrDefault(State())

    private fun saveState(state: State) {
        stateFile.parentFile?.mkdirs()
        // Erst daneben, dann an die Stelle: Eine halb geschriebene Datei läse sich als „noch nie abgeglichen“, und
        // gelöschte Notizen kämen vom Server zurück.
        val temp = File(stateFile.path + ".tmp")
        temp.writeText(PorridgeJson.encodeToString(State.serializer(), state))
        java.nio.file.Files.move(temp.toPath(), stateFile.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
    }

    /** Gibt zurück, wie viele Einträge der Datei dieses Gerät nicht lesen konnte. */
    private suspend fun syncFile(dav: WebDAV, run: Int): Int {
        val url = dav.file(dav.root, FILE_NAME)
        checkAccount(run)
        val state = loadState()
        repeat(4) { attempt ->
            val remote = dav.get(url)
            if (remote == null && attempt == 0) dav.makeFolder(dav.root)
            // Die Datenbank nimmt nichts von einem Konto, das nicht mehr das verbundene ist.
            checkAccount(run)
            val file = remote?.let { SyncMerge.parseFile(it.data.decodeToString()) } ?: JsonObject(emptyMap())
            val tombstones = file["deleted"] as? JsonObject
            val output = SyncMerge.withoutRetired(file).toMutableMap()
            output["version"] = JsonPrimitive(1)
            // Beginnt mit der Datei: Die Stimmen der anderen Plattform haben eigene Tombstones.
            val deleted = SyncMerge.withoutRetired(tombstones.orEmpty()).toMutableMap()
            var unreadable = 0
            val newBase = mutableMapOf<String, MutableMap<String, SyncBase>>()
            val merges = mutableMapOf<String, CollectionMerge>()
            for (collection in collections) {
                val merge = mergeCollection(collection, file, tombstones, state)
                merges[collection.key] = merge
                val result = merge.result
                unreadable += merge.unreadable.size
                output[collection.key] = JsonArray(result.merged.keys.sorted().map { result.merged.getValue(it) })
                deleted[collection.key] = JsonObject(result.tombstones.mapValues { JsonPrimitive(it.value) })
                // Ein nicht lesbarer Eintrag bleibt in der Datei, aber ohne Grundlage: Sonst läse ihn der nächste
                // Lauf als „hier gelöscht“, und er verschwände auf allen Geräten.
                newBase[collection.key] = result.merged.filterKeys { it !in merge.unreadable }
                    .mapValues { (id, record) -> SyncBase(merge.localHashes[id].orEmpty(), SyncMerge.hash(record), de.letzgo.porridge.logic.Todos.baseText(record)) }.toMutableMap()
            }
            pruneBuckets(merges, output, newBase)
            if (merges.values.any { it.wrote }) ownWriteAt = System.currentTimeMillis()
            output["deleted"] = JsonObject(deleted)
            val settingsBase = mergeSettings(file, output, state)

            val data = SyncMerge.canonical(JsonObject(output))
            val before = remote?.let { SyncMerge.canonical(file) }
            try {
                if (data != before) dav.put(data.toByteArray(), url, remote?.etag)
            } catch (_: SyncConflict) {
                return@repeat
            }
            // Inzwischen getrennt oder neu verbunden: Der Stand wurde zurückgesetzt und bleibt es.
            checkAccount(run)
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
    private class CollectionMerge(
        val result: SyncMerge.Result,
        val localHashes: Map<String, String>,
        val unreadable: Set<String>,
        /** Die Einträge, die dieser Lauf nicht anfasste ([Collection.frozen]). */
        val frozen: Set<String>,
        /** Ob der Lauf in die Datenbank schrieb. */
        var wrote: Boolean,
    )

    /**
     * iOS: der Teil von `NextcloudSync.syncFile` nach `Projects.pruneUnknown` — erst jetzt, mit jedem Bucket dieses Laufs
     * abgeglichen, ist ein Bucket, der fehlt, wirklich weg (auf einem anderen Gerät gelöscht): Notizen verlassen ihn, hier
     * und in der Datei, statt aus jeder Liste zu fallen.
     */
    private suspend fun pruneBuckets(
        merges: Map<String, CollectionMerge>,
        output: MutableMap<String, JsonElement>,
        newBase: MutableMap<String, MutableMap<String, SyncBase>>,
    ) {
        val folders = merges["folders"] ?: return
        val notes = merges["notes"] ?: return
        val records = notes.result.merged.toMutableMap()
        val pruned = Projects.pruneUnknown(PorridgeDatabase.shared.notes().all(), folders.result.merged.keys)
            // Eine eingefrorene Notiz behält den Eintrag der Datei; sie geht hoch, wenn sie fertig ist. Eine, deren Eintrag
            // hier nicht lesbar war, ebenso (ihr Eintrag ist neuer als die Notiz hier).
            .filter { it.id !in notes.frozen && it.id !in notes.unreadable && it.id in records }
        if (pruned.isEmpty()) return
        ownWriteAt = System.currentTimeMillis()
        PorridgeDatabase.shared.notes().upsertAll(pruned)
        notes.wrote = true
        val base = newBase.getOrPut("notes") { mutableMapOf() }
        for (note in pruned) {
            val record = noteRecord(note)
            records[note.id] = record
            val hash = SyncMerge.hash(record)
            base[note.id] = SyncBase(hash, hash, de.letzgo.porridge.logic.Todos.baseText(record))
        }
        output["notes"] = JsonArray(records.keys.sorted().map { records.getValue(it) })
    }

    private suspend fun <T> mergeCollection(collection: Collection<T>, file: JsonObject, tombstones: JsonObject?, state: State): CollectionMerge {
        val (models, locals) = collection.locals()
        val frozen = models.filter(collection.frozen).map(collection.id).toSet()
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
            frozen = frozen,
            now = System.currentTimeMillis(),
        )
        val localHashes = locals.mapValues { SyncMerge.hash(it.value.record) }.toMutableMap()
        val unreadable = mutableSetOf<String>()
        val byId = models.associateBy(collection.id)
        val applied = result.toApply.mapNotNull { (id, record) ->
            runCatching { collection.adopt(collection.decode(record), record, byId[id]) }
                .onSuccess { localHashes[id] = SyncMerge.hash(collection.record(it)) }
                .onFailure { unreadable += id }
                .getOrNull()
        }
        val gone = models.filter { collection.id(it) in result.toDelete }
        // Vor dem Schreiben: Die Meldung der Datenbank darüber ist die eigene und ruft keinen weiteren Lauf.
        if (applied.isNotEmpty() || gone.isNotEmpty()) ownWriteAt = System.currentTimeMillis()
        if (applied.isNotEmpty()) collection.save(applied)
        if (gone.isNotEmpty()) collection.delete(gone)
        return CollectionMerge(result, localHashes, unreadable, frozen, wrote = applied.isNotEmpty() || gone.isNotEmpty())
    }

    // Aufnahmen

    /** Die Aufnahmen der Notizen in der Datei und der hiesigen, die noch verarbeitet werden. */
    private suspend fun referencedRecordings(notes: JsonArray?): Set<String> {
        val inFile = notes.orEmpty().flatMap { element ->
            val record = element as? JsonObject ?: return@flatMap emptyList()
            val attachments = (record["attachmentsData"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?.let { runCatching { PorridgeJson.decodeFromString(ListSerializer(Attachment.serializer()), it) }.getOrNull() }.orEmpty()
            listOfNotNull((record["audioFileName"] as? JsonPrimitive)?.takeIf { it.isString }?.content) +
                (record["audioFileNames"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } +
                attachments.map { it.fileName }
        }
        val all = PorridgeDatabase.shared.notes().all()
        // Ein Teil, der nicht transkribiert werden konnte, bleibt für „Try Again“ auf diesem Gerät (er geht nie in die Datei).
        val local = all.filter(::isFrozen).flatMap { it.storedFileNames } + all.mapNotNull { it.pendingAudioFileName }
        return (inFile + local).toSet()
    }

    /** Lädt eine Aufnahme, wenn sie gebraucht wird. Jedes Netz ist recht: Jemand wartet darauf. */
    suspend fun fetchRecording(name: String) {
        val account = _status.value.account ?: throw NextcloudException("Nextcloud is not connected.")
        if (!AudioStore.isPlainName(name)) throw NextcloudException("This recording is not on Nextcloud yet.")
        val dav = WebDAV(account)
        dav.download(dav.file(dav.recordings, name), AudioStore.file(name))
    }

    /**
     * Aufnahmen, die das Gerät hat, gehen hoch, auf Wunsch nur im WLAN. Herunter kommen sie nur auf Anfrage ([fetchRecording]):
     * Transkript und Zusammenfassung sind ohnehin da, und nicht jedes Gerät braucht Stunden an Ton.
     */
    private suspend fun syncRecordings(dav: WebDAV, run: Int) {
        checkAccount(run)
        val all = PorridgeDatabase.shared.notes().all()
        val notes = all.filterNot(::isFrozen)
        val wanted = notes.flatMap { listOfNotNull(it.audioFileName) + it.audioFileNames + it.attachments.map { a -> a.fileName } }.toSet()
        val state = loadState()
        if (wanted.isEmpty() && state.orphans.isEmpty()) return
        val remote = dav.list(dav.recordings).toMutableSet()
        // Aufnahmen, die irgendwo gelöscht wurden: weg vom Server, und hier, wenn keine Notiz mehr darauf zeigt.
        var firstError: Throwable? = null
        if (state.orphans.isNotEmpty()) {
            val inUse = all.flatMap { it.storedFileNames }.toSet()
            val result = SyncMerge.eachFile(state.orphans.filter(AudioStore::isPlainName)) { name ->
                // `AccountChanged` ist ein Abbruch: `eachFile` reicht ihn durch.
                checkAccount(run)
                if (name in remote) dav.delete(dav.file(dav.recordings, name))
                remote -= name
                if (name !in inUse) AudioStore.delete(name)
            }
            checkAccount(run)
            // Was nicht gelöscht werden konnte, kommt beim nächsten Mal wieder dran.
            saveState(loadState().copy(orphans = result.failed))
            firstError = result.firstError
        }
        if (wanted.isNotEmpty()) {
            if (remote.isEmpty()) dav.makeFolder(dav.recordings)
            val result = SyncMerge.eachFile(wanted.sorted().filter(AudioStore::isPlainName)) { name ->
                // Keine Uploads mit den Zugangsdaten eines Kontos, das weg ist.
                checkAccount(run)
                if (AudioStore.exists(name) && name !in remote && uploadsAllowed()) {
                    dav.upload(AudioStore.file(name), dav.file(dav.recordings, name))
                    remote += name
                }
            }
            firstError = firstError ?: result.firstError
        }
        firstError?.let { throw it }
    }
}

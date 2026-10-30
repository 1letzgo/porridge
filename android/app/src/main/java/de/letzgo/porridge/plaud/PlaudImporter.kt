package de.letzgo.porridge.plaud

import android.content.Context
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.AudioStore
import de.letzgo.porridge.store.PorridgeDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.security.PrivateKey

/** Eine Aufnahme auf dem Plaud-Recorder. */
data class PlaudRecording(val sessionId: Long, val size: Long, val imported: Boolean) {
    val date: Long get() = sessionId * 1000
}

/** Was ein Import ergab: eine Audiodatei im Aufnahmespeicher. */
data class PlaudImportedAudio(val fileName: String, val duration: Double, val date: Long)

/** iOS: `PlaudImporter` — verbindet sich mit dem Recorder, listet seine Aufnahmen und übernimmt sie in Porridge. */
class PlaudImporter(context: Context) {
    private var account = PlaudAccount.load()
    private var privateKey: PrivateKey? = null
    @Volatile private var cancelRequested = false
    private val ble = PlaudBLE(context.applicationContext).apply { onLog = { _status.value = it } }
    private val cacheDir = File(context.cacheDir, "Plaud").apply { mkdirs() }

    private val _signedIn = MutableStateFlow(account.userToken != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()
    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status.asStateFlow()
    private val _recordings = MutableStateFlow<List<PlaudRecording>>(emptyList())
    val recordings: StateFlow<List<PlaudRecording>> = _recordings.asStateFlow()
    private val _isWorking = MutableStateFlow(false)
    val isWorking: StateFlow<Boolean> = _isWorking.asStateFlow()
    private val _importingId = MutableStateFlow<Long?>(null)
    val importingId: StateFlow<Long?> = _importingId.asStateFlow()
    private val _progress = MutableStateFlow(0f)
    val progress: StateFlow<Float> = _progress.asStateFlow()
    val errorMessage = MutableStateFlow<String?>(null)

    fun signIn(token: String, refreshToken: String?) {
        account = account.copy(userToken = token, refreshToken = refreshToken, apiHost = PlaudAPI.hostFromToken(token))
        account.save()
        _signedIn.value = true
    }

    fun signOut() {
        ble.disconnect()
        PlaudAccount.clear()
        account = PlaudAccount()
        privateKey = null
        _recordings.value = emptyList()
        _signedIn.value = false
        _status.value = ""
    }

    /** Die Anmeldung gilt nicht mehr: Tokens vergessen, Schlüssel und Signaturen behalten (sie bleiben gültig). */
    private fun expireSignIn() {
        account = account.copy(userToken = null, refreshToken = null)
        account.save()
        _signedIn.value = false
        _recordings.value = emptyList()
        _status.value = ""
    }

    /** Ein Token, das Plaud noch annimmt; kurz vor Ablauf mit dem Refresh-Token erneuert (wie web.plaud.ai). */
    private suspend fun validUserToken(): String {
        val token = account.userToken ?: throw PlaudAPIException.Message("Please sign in to Plaud first.")
        val expiry = PlaudAPI.expiry(token) ?: return token
        if (expiry - System.currentTimeMillis() >= 120_000) return token
        val refresh = account.refreshToken ?: run { expireSignIn(); throw PlaudAPIException.Unauthorized() }
        _status.value = "Renewing the Plaud sign-in …"
        return try {
            val renewed = PlaudAPI(token, account.apiHost).refreshUserToken(refresh)
            account = account.copy(userToken = renewed.userToken, refreshToken = renewed.refreshToken ?: refresh, apiHost = renewed.host)
            account.save()
            renewed.userToken
        } catch (e: Throwable) {
            PlaudLog.log("token renewal failed: $e")
            expireSignIn()
            throw PlaudAPIException.Unauthorized()
        }
    }

    /** Verbindet sich (falls nötig) und liest die Aufnahmen. */
    suspend fun refresh() {
        if (!_signedIn.value || _isWorking.value || _importingId.value != null) return
        _isWorking.value = true
        try {
            ensureReady()
            val imported = importedSessions
            _recordings.value = ble.listSessions().map { PlaudRecording(it.sessionId, it.size, it.sessionId in imported) }.sortedByDescending { it.sessionId }
            _status.value = if (_recordings.value.isEmpty()) "No recordings on the recorder." else ""
        } catch (e: Throwable) {
            ble.disconnect()
            errorMessage.value = e.message
            _status.value = ""
        } finally {
            _isWorking.value = false
        }
    }

    /** Lädt eine Aufnahme vom Recorder, entschlüsselt sie und legt sie als Audio ab. */
    suspend fun importRecording(recording: PlaudRecording): PlaudImportedAudio? {
        if (_importingId.value != null || _isWorking.value) return null
        _importingId.value = recording.sessionId
        _progress.value = 0f
        cancelRequested = false
        try {
            ensureReady()
            val key = privateKey ?: throw PlaudBLEException.Message("missing keys")
            val part = File(cacheDir, "plaud_${recording.sessionId}.part")
            val raw = pullWithResume(PlaudRecordingInfo(recording.sessionId, recording.size), part)
            part.delete()
            if (!raw.copyOfRange(0, minOf(8, raw.size)).contentEquals("PLAUD.AI".toByteArray())) throw PlaudBLEException.Message("The recorder sent the recording in a format Porridge does not know.")
            _status.value = "Converting …"
            val ogg = withContext(Dispatchers.Default) { PlaudCrypto.decryptRecordingFile(raw, key) }
            // Die Chiffre hat keine Prüfsumme: die Seiten-Prüfsummen des Audios beweisen, dass die Kopie heil ist.
            if (!PlaudCrypto.isCompleteOgg(ogg)) throw PlaudBLEException.Message("The copy of this recording is damaged. Please try again.")
            val fileName = AudioStore.newFileName("m4a")
            val duration = withContext(Dispatchers.Default) { OpusOggDecoder.decode(ogg, AudioStore.file(fileName)) }
            markImported(recording.sessionId)
            _recordings.value = _recordings.value.map { if (it.sessionId == recording.sessionId) it.copy(imported = true) else it }
            _status.value = ""
            return PlaudImportedAudio(fileName, duration, recording.date)
        } catch (e: PlaudBLEException.Cancelled) {
            _status.value = ""
            return null
        } catch (e: Throwable) {
            errorMessage.value = e.message
            _status.value = ""
            return null
        } finally {
            _importingId.value = null
        }
    }

    fun cancelImport() {
        if (_importingId.value == null) return
        cancelRequested = true
        ble.cancelTransfer()
    }

    /** Download mit Fortschritt auf der Platte; ein abgebrochener Transfer setzt nach der Teildatei fort. */
    private suspend fun pullWithResume(info: PlaudRecordingInfo, part: File): ByteArray {
        val total = info.size
        var reconnects = 0
        while (true) {
            var saved = if (part.exists()) part.readBytes() else ByteArray(0)
            if (total > 0 && saved.size > total) { saved = ByteArray(0); part.delete() }
            if (total > 0 && saved.size.toLong() == total) return saved
            RandomAccessFile(part, "rw").use { it.setLength(saved.size.toLong()) }
            val out = java.io.FileOutputStream(part, true)
            try {
                return ble.pullFile(info, saved, onChunk = { out.write(it) }) { got, all -> if (all > 0) _progress.value = got.toFloat() / all }.data
            } catch (e: PlaudBLEException) {
                if (!e.isRetryable || reconnects >= 2 || cancelRequested) throw e
                reconnects++
                _status.value = "Connection lost. Reconnecting …"
                ble.disconnect()
                ensureReady()
            } finally {
                runCatching { out.close() }
            }
        }
    }

    private suspend fun ensureReady() {
        val token = validUserToken()
        val api = PlaudAPI(token, account.apiHost)
        if (account.privatePEM == null) {
            _status.value = "Fetching your encryption key …"
            try {
                val (priv, pub, host) = api.genKey()
                account = account.copy(privatePEM = priv, publicPEM = pub, apiHost = host)
                api.host = host
                account.save()
            } catch (e: PlaudAPIException.Unauthorized) {
                expireSignIn(); throw e
            }
        }
        if (privateKey == null) account.privatePEM?.let { privateKey = PlaudCrypto.importRSAPrivateKey(it) }
        if (ble.isConnected) return
        // Bluetooth-Verbindungen scheitern aus vorübergehenden Gründen; jeder Versuch beginnt sauber.
        val attempts = 3
        for (attempt in 1..attempts) {
            try {
                connectAndUnlock(api, token)
                return
            } catch (e: Throwable) {
                ble.disconnect()
                PlaudLog.log("connect attempt $attempt failed: $e")
                val retryable = (e as? PlaudBLEException)?.isRetryable ?: false
                if (!retryable || attempt >= attempts) throw e
                _status.value = "Connection failed. Retrying ${attempt + 1} of $attempts …"
                delay(attempt * 1500L)
            }
        }
    }

    private suspend fun connectAndUnlock(api: PlaudAPI, token: String) {
        _status.value = "Looking for the recorder …"
        ble.connect(account.signatures.keys)
        val serial = ble.discoveredSerial ?: account.lastSerial.takeIf { ble.isKnownPeripheral }
            ?: throw PlaudBLEException.Message("Could not read the serial number of the recorder.")
        if (account.signatures[serial] == null) {
            _status.value = "Authorising the recorder …"
            try {
                val (sig, host) = api.snSign(serial)
                account = account.copy(signatures = account.signatures + (serial to sig), apiHost = host)
                account.save()
            } catch (e: PlaudAPIException.Unauthorized) {
                expireSignIn()
                throw PlaudBLEException.Fatal(e.message ?: "")
            } catch (e: Throwable) {
                throw PlaudBLEException.Fatal("Could not get the recorder's signature from Plaud: ${e.message}")
            }
        }
        val publicPEM = account.publicPEM ?: throw PlaudBLEException.Message("missing keys")
        val signature = account.signatures.getValue(serial)
        val key = privateKey ?: throw PlaudBLEException.Message("missing keys")
        ble.unlockProtocol20(signature, key, publicPEM)
        ble.handshake(PlaudAPI.subject(token) ?: serial)
        account = account.copy(lastSerial = serial)
        account.save()
        // Aufnahme-IDs sind Startzeiten der Recorder-Uhr; die App hält sie richtig.
        runCatching { ble.syncClock() }.onFailure { PlaudLog.log("clock sync failed: $it") }
        _status.value = ""
    }

    fun disconnect() = ble.disconnect()

    companion object {
        private val importedSessions: Set<Long> get() = Prefs.stringSet(Keys.PLAUD_IMPORTED).mapNotNull { it.toLongOrNull() }.toSet()
        private fun markImported(id: Long) = Prefs.set(Keys.PLAUD_IMPORTED, Prefs.stringSet(Keys.PLAUD_IMPORTED) + id.toString())

        /** Legt eine übernommene Aufnahme als neue Notiz an und startet die Transkription. */
        suspend fun addNote(audio: PlaudImportedAudio): Note {
            val info = AudioStore.audioInfo(audio.fileName)
            val note = Note(
                createdAt = audio.date, updatedAt = audio.date, title = Note.defaultMeetingTitle(audio.date), statusRaw = ProcessingStatus.RECORDED.raw,
                audioFileName = audio.fileName, duration = audio.duration, inputName = "Plaud", channelCount = info?.second ?: 1,
            )
            PorridgeDatabase.shared.notes().upsert(note)
            ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
            return note
        }
    }
}

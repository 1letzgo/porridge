// Ported from roopen219/plaude-archiver (MIT License, https://github.com/roopen219/plaude-archiver):
// the Plaud Note Pro Bluetooth protocol, reverse-engineered there.
package de.letzgo.porridge.plaud

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.Prefs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.security.PrivateKey
import java.util.Base64
import java.util.TimeZone
import java.util.UUID

data class PlaudRecordingInfo(val sessionId: Long, val size: Long)
class PlaudPulledFile(val data: ByteArray, val tailCRC: Int?)

/** iOS: `PlaudBLEError`. */
sealed class PlaudBLEException(message: String) : Exception(message) {
    /** Verbindungs- oder Protokollproblem; eine neue Verbindung kann helfen. */
    class Message(message: String) : PlaudBLEException(message)
    /** Gerät oder Funk haben nicht rechtzeitig geantwortet. */
    class Timeout(message: String) : PlaudBLEException(message)
    /** Ein neuer Versuch hilft jetzt nicht (Berechtigung, Bluetooth aus, nicht gefunden, abgelehnt). */
    class Fatal(message: String) : PlaudBLEException(message)
    class Cancelled : PlaudBLEException("cancelled")

    val isRetryable get() = this is Message || this is Timeout
}

/**
 * iOS: `PlaudBLE` (Services/Plaud/PlaudBLE.swift) — Verbindung zum Plaud-Recorder über Bluetooth LE, Entsperren
 * (Protokoll 20), Handshake, Aufnahmen auflisten und laden. Android-Eigenheiten: eine GATT-Operation zur Zeit
 * ([gattOp]), Benachrichtigungen über den CCCD, MTU-Aushandlung.
 */
@SuppressLint("MissingPermission")
class PlaudBLE(private val context: Context) {
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var session: PlaudSession? = null
    private var handshakeDone = false
    private var portVersion = 20
    private var mtu = 23
    @Volatile private var connected = false

    private var packets = Channel<ByteArray>(Channel.UNLIMITED)
    private val sendLock = Mutex()
    private val opLock = Mutex()
    private var pendingOp: CompletableDeferred<Int>? = null
    private var pendingConnect: CompletableDeferred<Boolean>? = null

    var onLog: (String) -> Unit = {}
    /** Eine bestehende Verbindung ist ohne Zutun abgerissen. */
    var onLinkLost: () -> Unit = {}
    var discoveredName: String? = null
        private set
    var discoveredSerial: String? = null
        private set
    private var device: BluetoothDevice? = null
    private var knownSerials: Set<String> = emptySet()

    private fun log(s: String) { onLog(s); PlaudLog.log(s) }
    private fun trace(s: String) = PlaudLog.log("ble: $s")

    val isConnected: Boolean get() = connected && writeChar != null && session != null && handshakeDone
    /** Das verbundene Gerät hat zuletzt einen Handshake geschafft; seine gespeicherte Seriennummer gilt. */
    val isKnownPeripheral: Boolean get() = device != null && device?.address == Prefs.string(Keys.PLAUD_LAST_PERIPHERAL)

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (g != gatt) return
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connected = true
                pendingConnect?.complete(true)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val wasReady = isConnected
                connected = false
                pendingConnect?.complete(false)
                pendingOp?.complete(-1)
                packets.close(PlaudBLEException.Message("The device disconnected."))
                if (wasReady) { log("The device disconnected."); onLinkLost() }
            }
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { pendingOp?.complete(status) }
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this@PlaudBLE.mtu = mtu
            pendingOp?.complete(status)
        }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) { pendingOp?.complete(status) }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) { pendingOp?.complete(status) }
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") received(c.value ?: return)
        }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) = received(value)
    }

    private fun received(raw: ByteArray) {
        val s = session
        val pkt = if (s != null) s.open(raw) ?: return else raw // nicht entschlüsselbar oder Wiederholung: verwerfen
        // Ereignisse (cmd 19) sind keine Antworten; manche wollen eine Bestätigung [type u16][seq u16].
        if (pkt.size >= 3 && pkt[0] == 1.toByte() && PlaudProto.cmdOf(pkt) == PlaudProto.CMD_EVENT) {
            if (pkt.size >= 11 && pkt[7] == 1.toByte()) {
                val ack = PlaudProto.command(PlaudProto.CMD_EVENT, PlaudProto.u16le(PlaudProto.le16(pkt, 3)) + PlaudProto.u16le(PlaudProto.le16(pkt, 5)))
                Thread { runCatching { kotlinx.coroutines.runBlocking { send(ack) } } }.start()
            }
            return
        }
        packets.trySend(pkt)
    }

    /** Eine GATT-Operation: Android erlaubt nur eine zur Zeit; der Rückruf meldet ihr Ende. */
    private suspend fun gattOp(timeoutMs: Long, what: String, start: () -> Boolean): Int = opLock.withLock {
        val done = CompletableDeferred<Int>()
        pendingOp = done
        if (!start()) { pendingOp = null; throw PlaudBLEException.Message("$what could not start") }
        try {
            withTimeout(timeoutMs) { done.await() }
        } catch (e: TimeoutCancellationException) {
            throw PlaudBLEException.Timeout(what)
        } finally {
            pendingOp = null
        }
    }

    // Verbindung

    /** Finden, verbinden und den GATT-Link vorbereiten. Beginnt immer sauber; nach jedem Fehler erneut aufrufbar. */
    suspend fun connect(knownSerials: Set<String> = emptySet()) {
        tearDown()
        this.knownSerials = knownSerials
        val adapter = manager.adapter ?: throw PlaudBLEException.Fatal("This phone has no Bluetooth.")
        if (!adapter.isEnabled) throw PlaudBLEException.Fatal("Bluetooth is turned off.")
        try {
            val d = findDevice()
            device = d
            log("Connecting to ${discoveredName ?: "the device"}…")
            packets = Channel(Channel.UNLIMITED)
            val wait = CompletableDeferred<Boolean>()
            pendingConnect = wait
            gatt = d.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            val ok = try { withTimeout(15_000) { wait.await() } } catch (e: TimeoutCancellationException) { throw PlaudBLEException.Timeout("The device did not accept the connection.") }
            if (!ok) throw PlaudBLEException.Message("The device did not accept the connection.")
            val g = gatt!!
            trace("connected; discovering services")
            if (gattOp(10_000, "The device did not list its services.") { g.discoverServices() } != BluetoothGatt.GATT_SUCCESS) throw PlaudBLEException.Message("service discovery failed")
            val service = g.getService(UUID.fromString(PlaudProto.SERVICE)) ?: throw PlaudBLEException.Message("Plaud service not found on the device.")
            notifyChar = service.getCharacteristic(UUID.fromString(PlaudProto.NOTIFY_CHAR))
            writeChar = service.getCharacteristic(UUID.fromString(PlaudProto.WRITE_CHAR))
            val n = notifyChar ?: throw PlaudBLEException.Message("The device is missing the Plaud characteristics.")
            if (writeChar == null) throw PlaudBLEException.Message("The device is missing the Plaud characteristics.")
            // Größere Pakete: das Signatur-Stück (104 Byte) passt sonst nicht in eine Schreiboperation ohne Antwort.
            runCatching { gattOp(5_000, "mtu") { g.requestMtu(247) } }
            trace("mtu = $mtu")
            // Benachrichtigungen vor dem ersten Paket einschalten, sonst geht die erste Antwort verloren (Android: CCCD schreiben).
            g.setCharacteristicNotification(n, true)
            val cccd = n.getDescriptor(UUID.fromString(PlaudProto.CCCD)) ?: throw PlaudBLEException.Message("The device did not turn on notifications.")
            val status = gattOp(10_000, "The device did not turn on notifications.") {
                if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
                else @Suppress("DEPRECATION") run { cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(cccd) }
            }
            if (status != BluetoothGatt.GATT_SUCCESS) throw PlaudBLEException.Message("enabling notifications failed ($status)")
            log("Connected${discoveredName?.let { " to $it" } ?: ""}.")
        } catch (e: Throwable) {
            tearDown()
            throw e
        }
    }

    private data class Candidate(val device: BluetoothDevice, var name: String?, var serial: String?, var rssi: Int)

    /** Ein Gerät, mit dem das System schon verbunden ist, sendet keine Werbung; erst danach scannen. */
    private suspend fun findDevice(): BluetoothDevice {
        discoveredName = null; discoveredSerial = null
        val known = Prefs.string(Keys.PLAUD_LAST_PERIPHERAL)
        val held = manager.getConnectedDevices(BluetoothProfile.GATT).filter { it.address == known || it.name?.contains("plaud", true) == true }
        held.firstOrNull { it.address == known }?.let { discoveredName = it.name; trace("using a link the system already holds: ${it.address}"); return it }
        log("Looking for a Plaud device…")
        val scanner = manager.adapter.bluetoothLeScanner ?: throw PlaudBLEException.Fatal("Bluetooth is not available.")
        val candidates = HashMap<String, Candidate>()
        val chosen = CompletableDeferred<Candidate>()
        var pickAt = 0L
        val cb = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                if (chosen.isCompleted) return
                val record = result.scanRecord
                val name = result.device.name ?: record?.deviceName
                val uuids = record?.serviceUuids?.map { it.uuid.toString() } ?: emptyList()
                val isPlaud = result.device.address == known || PlaudProto.ADVERT in uuids || PlaudProto.SERVICE in uuids || name?.lowercase()?.contains("plaud") == true
                if (!isPlaud) return
                // Android trennt die Firmen-ID ab; die iOS-Logik erwartet sie vorn.
                val mfr = record?.manufacturerSpecificData
                val serial = if (mfr != null && mfr.size() > 0) {
                    val id = mfr.keyAt(0)
                    PlaudProto.serial(byteArrayOf((id and 0xff).toByte(), ((id shr 8) and 0xff).toByte()) + mfr.valueAt(0))
                } else null
                val c = candidates.getOrPut(result.device.address) { Candidate(result.device, null, null, result.rssi) }
                c.name = name ?: c.name
                c.serial = serial ?: c.serial
                c.rssi = result.rssi
                // Ein sicherer Treffer sofort; eine andere Seriennummer erst nach 1,5 s, wenn nichts Besseres kam.
                if (c.device.address == known || c.serial?.let { it in knownSerials } == true) { chosen.complete(c); return }
                if (c.serial != null && pickAt == 0L) pickAt = System.currentTimeMillis() + 1500
            }
            override fun onScanFailed(errorCode: Int) { chosen.completeExceptionally(PlaudBLEException.Fatal("Bluetooth scan failed ($errorCode).")) }
        }
        scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
        try {
            val c = withTimeout(20_000) {
                while (!chosen.isCompleted) {
                    if (pickAt != 0L && System.currentTimeMillis() >= pickAt) {
                        candidates.values.filter { it.serial != null }.maxByOrNull { it.rssi }?.let { chosen.complete(it) }
                    }
                    delay(100)
                }
                chosen.await()
            }
            discoveredName = c.name
            c.serial?.let { discoveredSerial = it }
            log("Found ${c.name ?: "device"}${c.serial?.let { " (serial $it)" } ?: ""}.")
            return c.device
        } catch (e: TimeoutCancellationException) {
            throw PlaudBLEException.Fatal("Could not find the device. Make sure it is on, nearby, and not connected to the Plaud phone app.")
        } finally {
            runCatching { scanner.stopScan(cb) }
        }
    }

    fun disconnect() = tearDown()

    private fun tearDown() {
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null; writeChar = null; notifyChar = null; device = null
        session = null; handshakeDone = false; portVersion = 20; mtu = 23; connected = false
        packets.close()
        pendingOp?.complete(-1)
        pendingConnect?.complete(false)
    }

    // Pakete

    private suspend fun nextPacket(timeoutMs: Long): ByteArray = try {
        withTimeout(timeoutMs) { packets.receive() }
    } catch (e: TimeoutCancellationException) {
        throw PlaudBLEException.Timeout("timed out waiting for the device")
    } catch (e: kotlinx.coroutines.channels.ClosedReceiveChannelException) {
        throw PlaudBLEException.Message("not connected")
    }

    /** Sendungen laufen nacheinander: jedes verschlüsselte Paket trägt die nächste Folgenummer. */
    private suspend fun send(data: ByteArray) = sendLock.withLock {
        val g = gatt ?: throw PlaudBLEException.Message("not connected")
        val w = writeChar ?: throw PlaudBLEException.Message("not connected")
        if (!connected) throw PlaudBLEException.Message("not connected")
        val payload = session?.seal(data) ?: data
        val noResponse = payload.size <= mtu - 3
        val type = if (noResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        if (!noResponse && w.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0) {
            throw PlaudBLEException.Message("packet of ${payload.size} bytes is over the ${mtu - 3}-byte link limit")
        }
        val status = gattOp(10_000, "The device did not confirm a write.") {
            if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(w, payload, type) == BluetoothGatt.GATT_SUCCESS
            else @Suppress("DEPRECATION") run { w.writeType = type; w.value = payload; g.writeCharacteristic(w) }
        }
        if (status != BluetoothGatt.GATT_SUCCESS) throw PlaudBLEException.Message("write failed ($status)")
    }

    private suspend fun waitCommand(cmds: Set<Int>, timeoutMs: Long): ByteArray {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) throw PlaudBLEException.Timeout("timed out waiting for the device")
            val pkt = nextPacket(remaining)
            if (pkt.size >= 3 && pkt[0] == 1.toByte() && PlaudProto.cmdOf(pkt) in cmds) return pkt
        }
    }

    // Entsperren (Protokoll 20)

    suspend fun unlockProtocol20(signatureBase64: String, privateKey: PrivateKey, publicKeyPEM: String) {
        val sig = runCatching { Base64.getDecoder().decode(signatureBase64) }.getOrNull() ?: throw PlaudBLEException.Fatal("bad signature base64")
        val parts = HashMap<Int, ByteArray>()
        var total: Int? = null
        var sawFE11 = false
        session = null; handshakeDone = false

        suspend fun collect(timeoutMs: Long): ByteArray {
            val pkt = nextPacket(timeoutMs)
            if (pkt.size < 2) return pkt
            when (PlaudProto.le16(pkt, 0)) {
                PlaudProto.FE30 -> throw PlaudBLEException.Fatal("device started an ECC session (0xFE30); this build only supports protocol 20")
                PlaudProto.FE11 -> sawFE11 = true
                PlaudProto.FE12 -> if (pkt.size >= 4) { sawFE11 = false; total = pkt[2].toInt() and 0xff; parts[pkt[3].toInt() and 0xff] = pkt }
            }
            return pkt
        }
        // Nach jedem Stück auf Antwort warten; ein Note Pro antwortet nur auf das letzte.
        suspend fun sendChunks(cmd: Int, blob: ByteArray) {
            val n = (blob.size + 99) / 100
            for (i in 0 until n) {
                send(PlaudProto.feChunk(cmd, n, i, blob.copyOfRange(i * 100, minOf((i + 1) * 100, blob.size))))
                try { collect(if (i < n - 1) 300 else 10_000) } catch (e: PlaudBLEException.Timeout) { trace("no reply to chunk ${i + 1}/$n of 0x${cmd.toString(16)}") }
            }
        }
        log("Sending the device signature (${sig.size} bytes)…")
        sendChunks(PlaudProto.FE10, sig)
        if (sawFE11) {
            log("First bind: sending your public key…")
            parts.clear()
            sendChunks(PlaudProto.FE12, publicKeyPEM.toByteArray())
        }
        log("Waiting for the session key…")
        try {
            while (total == null || parts.size < (total ?: 1)) collect(10_000)
        } catch (e: PlaudBLEException.Timeout) {
            throw PlaudBLEException.Timeout("The device did not send the session key (got ${parts.size} of ${total?.toString() ?: "?"} parts).")
        }
        val blob = parts.keys.sorted().fold(ByteArray(0)) { acc, k -> acc + parts.getValue(k).copyOfRange(4, parts.getValue(k).size) }
        val plain = try { PlaudCrypto.rsaDecryptPKCS1(blob, privateKey) } catch (e: Throwable) {
            throw PlaudBLEException.Fatal("Could not decrypt the session key: the device may hold a different account's key. (${e.message})")
        }
        if (plain.size < 56) throw PlaudBLEException.Message("session secret too short (${plain.size})")
        val key = plain.copyOfRange(0, 32)
        val nonce = plain.copyOfRange(32, 44)
        val aad = plain.copyOfRange(44, 56)
        // Der Rest muss zu „PLAUD.AI“ entschlüsseln.
        val tail = plain.copyOfRange(56, plain.size)
        if (tail.size >= 16) {
            val check = PlaudCrypto.aeadOpen(tail, key, nonce, aad)
            if (check == null || !check.contentEquals("PLAUD.AI".toByteArray())) throw PlaudBLEException.Message("session check failed")
        }
        session = PlaudSession(key, nonce, aad)
        log("Encrypted session established.")
    }

    // Handshake, Liste, Laden

    suspend fun handshake(token: String) {
        send(PlaudProto.handshake(token, portVersion, false))
        var rsp = waitCommand(setOf(PlaudProto.CMD_HANDSHAKE, PlaudProto.CMD_GET_SSN), 10_000)
        if (PlaudProto.cmdOf(rsp) == PlaudProto.CMD_GET_SSN) {
            log("Second handshake…")
            send(PlaudProto.handshake(token, portVersion, true))
            rsp = waitCommand(setOf(PlaudProto.CMD_HANDSHAKE), 10_000)
        }
        val status = if (rsp.size > 3) rsp[3].toInt() and 0xff else -1
        if (status != 0) throw PlaudBLEException.Fatal("The device refused the handshake (status $status). It may be bound to another account.")
        if (rsp.size >= 6) portVersion = PlaudProto.le16(rsp, 4)
        handshakeDone = true
        // Nur ein Gerät mit geschafftem Handshake wird als unseres gemerkt.
        device?.let { Prefs.set(Keys.PLAUD_LAST_PERIPHERAL, it.address) }
        log("Handshake OK (protocol $portVersion).")
    }

    suspend fun listSessions(): List<PlaudRecordingInfo> {
        send(PlaudProto.sessionList())
        val files = mutableListOf<PlaudRecordingInfo>()
        val seen = HashSet<Long>()
        var total: Int? = null
        while (total == null || files.size < total!!) {
            val b = waitCommand(setOf(PlaudProto.CMD_GET_REC_SESSIONS), 15_000)
            if (total == null && b.size >= 9) total = PlaudProto.le16(b, 7)
            if (b.size < 11) continue
            if (PlaudProto.le16(b, 9) != files.size) continue
            val entry = if (portVersion == 1) 8 else if (portVersion <= 6) 9 else 10
            var off = 11
            while (off + entry <= b.size) {
                val sid = PlaudProto.le32(b, off)
                if (seen.add(sid)) files += PlaudRecordingInfo(sid, PlaudProto.le32(b, off + 4))
                off += entry
            }
        }
        return files
    }

    @Volatile private var transferCancelled = false

    fun cancelTransfer() {
        transferCancelled = true
        packets.trySend(ByteArray(0)) // weckt einen wartenden Leser
    }

    /**
     * Lädt eine Aufnahme. [existing] sind Bytes eines früheren, abgebrochenen Downloads; es geht danach weiter. Eine
     * Lücke oder ein Hänger startet ab dem letzten guten Byte neu.
     */
    suspend fun pullFile(rec: PlaudRecordingInfo, existing: ByteArray = ByteArray(0), onChunk: (ByteArray) -> Unit = {}, onProgress: (Long, Long) -> Unit): PlaudPulledFile {
        val data = java.io.ByteArrayOutputStream().apply { write(existing) }
        val total = rec.size
        var restarts = 0
        var progressAtRestart = data.size()
        transferCancelled = false
        while (true) {
            var finished: Int? = null
            var ended = false
            try {
                val outcome = pullRange(rec, data.size().toLong()) { chunk ->
                    data.write(chunk)
                    onChunk(chunk)
                    onProgress(data.size().toLong(), total)
                }
                if (outcome != null) { ended = true; finished = outcome.takeIf { it >= 0 } }
            } catch (e: PlaudBLEException.Timeout) {
                trace("transfer of ${rec.sessionId} stalled at ${data.size()} of $total")
            } catch (e: PlaudBLEException.Cancelled) {
                runCatching { stopTransfer() }
                throw e
            }
            if (transferCancelled) { runCatching { stopTransfer() }; throw PlaudBLEException.Cancelled() }
            if (ended && (total == 0L || data.size().toLong() == total)) return PlaudPulledFile(data.toByteArray(), finished)
            if (total > 0 && data.size() > total) throw PlaudBLEException.Message("download overran: got ${data.size()} of $total bytes")
            if (data.size() > progressAtRestart) { restarts = 0; progressAtRestart = data.size() }
            restarts++
            if (restarts > 3 || !connected) throw PlaudBLEException.Message("incomplete download: got ${data.size()} of $total bytes")
            log("Resuming the download at ${data.size() * 100 / maxOf(total, 1)}%…")
            runCatching { stopTransfer() }
        }
    }

    /** Eine Anfrage ab [from] bis zum Ende. Liefert am Schlusspaket die CRC (oder -1), bei einer Lücke null. */
    private suspend fun pullRange(rec: PlaudRecordingInfo, from: Long, append: (ByteArray) -> Unit): Int? {
        while (packets.tryReceive().isSuccess) Unit // Reste einer früheren Übertragung
        send(PlaudProto.syncStart(rec.sessionId, from, rec.size))
        val head = waitCommand(setOf(PlaudProto.CMD_SYNC_FILE_START), 15_000)
        if (head.size > 7 && head[7].toInt() != 0) throw PlaudBLEException.Message("device refused sync, status=${head[7].toInt() and 0xff}")
        var pos = from
        while (true) {
            if (transferCancelled) throw PlaudBLEException.Cancelled()
            val pkt = nextPacket(20_000)
            if (pkt.isEmpty()) continue
            // Schluss: [01][1d 00][session u32][crc u16]
            if (pkt.size >= 3 && pkt[0] == 1.toByte() && PlaudProto.cmdOf(pkt) == PlaudProto.CMD_SYNC_FILE_TAIL) return if (pkt.size >= 9) PlaudProto.le16(pkt, 7) else -1
            if (pkt[0] != 2.toByte()) continue
            var i = 1
            if (portVersion >= 7) {
                if (pkt.size < 5 || PlaudProto.le32(pkt, 1) != rec.sessionId) continue
                i = 5
            }
            if (pkt.size < i + 5) continue
            val offset = PlaudProto.le32(pkt, i)
            if (offset == 0xFFFFFFFFL) return -1
            val n = pkt[i + 4].toInt() and 0xff
            val chunk = pkt.copyOfRange(i + 5, minOf(i + 5 + n, pkt.size))
            if (offset < pos) continue          // schon da
            if (offset > pos) return null       // ein Paket fehlt
            append(chunk)
            pos += chunk.size
        }
    }

    /** syncFileStop: cmd 29 ohne Daten; das Gerät antwortet mit cmd 30. */
    suspend fun stopTransfer() {
        send(PlaudProto.command(PlaudProto.CMD_SYNC_FILE_STOP))
        waitCommand(setOf(PlaudProto.CMD_SYNC_FILE_STOP_RSP), 5_000)
        while (packets.tryReceive().isSuccess) Unit
    }

    /** syncTime (cmd 4): [Unix-Sekunden u32][Zeitzone Stunden i8][Minuten i8]. Aufnahme-IDs sind Startzeiten dieser Uhr. */
    suspend fun syncClock(now: Long = System.currentTimeMillis()) {
        val offset = TimeZone.getDefault().getOffset(now) / 60_000
        send(PlaudProto.command(PlaudProto.CMD_TIME_SYNC, PlaudProto.u32le(now / 1000) + byteArrayOf((offset / 60).toByte(), (offset % 60).toByte())))
        waitCommand(setOf(PlaudProto.CMD_TIME_SYNC), 5_000)
    }
}

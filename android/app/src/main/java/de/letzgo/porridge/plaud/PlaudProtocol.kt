// Ported from roopen219/plaude-archiver (MIT License, https://github.com/roopen219/plaude-archiver):
// the Plaud Note Pro Bluetooth protocol and file format, reverse-engineered there.
package de.letzgo.porridge.plaud

/** iOS: `PlaudProto` — Tinnotech-BLE-Protokoll (com.tinnotech.penblesdk), durchweg little-endian. */
object PlaudProto {
    // GATT des Plaud-Dienstes (16-Bit-UUIDs auf der Bluetooth-Basis).
    const val SERVICE = "00001910-0000-1000-8000-00805f9b34fb"
    const val NOTIFY_CHAR = "00002bb0-0000-1000-8000-00805f9b34fb" // Gerät → App
    const val WRITE_CHAR = "00002bb1-0000-1000-8000-00805f9b34fb"  // App → Gerät
    const val ADVERT = "0000504c-0000-1000-8000-00805f9b34fb"
    const val CCCD = "00002902-0000-1000-8000-00805f9b34fb"

    const val CMD_HANDSHAKE = 1
    const val CMD_GET_SSN = 2
    const val CMD_TIME_SYNC = 4
    const val CMD_EVENT = 19
    const val CMD_GET_REC_SESSIONS = 26
    const val CMD_SYNC_FILE_START = 28
    const val CMD_SYNC_FILE_TAIL = 29 // Antwort; als Anfrage stoppt 29 die Übertragung
    const val CMD_SYNC_FILE_STOP = 29
    const val CMD_SYNC_FILE_STOP_RSP = 30
    const val FE10 = 0xFE10 // App → Gerät: Seriennummer-Signatur
    const val FE11 = 0xFE11 // Gerät → App: schick deinen öffentlichen Schlüssel
    const val FE12 = 0xFE12 // Sitzungsgeheimnis / Träger des öffentlichen Schlüssels
    const val FE30 = 0xFE30 // ECC-Start (Protokoll 30) — hier nicht unterstützt

    fun u16le(v: Int) = byteArrayOf((v and 0xff).toByte(), ((v ushr 8) and 0xff).toByte())
    fun u32le(v: Long) = byteArrayOf((v and 0xff).toByte(), ((v ushr 8) and 0xff).toByte(), ((v ushr 16) and 0xff).toByte(), ((v ushr 24) and 0xff).toByte())

    /** [0x01][cmd u16][params] */
    fun command(cmd: Int, params: ByteArray = ByteArray(0)) = byteArrayOf(1) + u16le(cmd) + params

    /** [01][01 00][02 00][P bei pv ≥ 3][Token auf 16 oder 32 ASCII-Zeichen mit „0“ aufgefüllt] */
    fun handshake(token: String, portVersion: Int, second: Boolean): ByteArray {
        val n = if (portVersion >= 9) 32 else 16
        val t = token.toByteArray().let { if (it.size < n) it + ByteArray(n - it.size) { 0x30 } else it }.copyOf(n)
        var body = byteArrayOf(2, 0)
        if (portVersion >= 3) body += (if (second) 1 else 0).toByte()
        return command(CMD_HANDSHAKE, body + t)
    }

    /** [now u32][Start-Sitzung u32][flag u8] */
    fun sessionList(start: Long = 0, flag: Int = 0) = command(CMD_GET_REC_SESSIONS, u32le(System.currentTimeMillis() / 1000) + u32le(start) + byteArrayOf(flag.toByte()))

    /** [session u32][start u32][end u32] */
    fun syncStart(session: Long, start: Long, end: Long) = command(CMD_SYNC_FILE_START, u32le(session) + u32le(start) + u32le(end))

    /** [cmd u16][total u8][index u8][≤ 100 Byte] für FE10/FE12-Stücke. */
    fun feChunk(cmd: Int, total: Int, index: Int, slice: ByteArray) = u16le(cmd) + byteArrayOf(total.toByte(), index.toByte()) + slice

    fun le16(d: ByteArray, o: Int) = (d[o].toInt() and 0xff) or ((d[o + 1].toInt() and 0xff) shl 8)
    fun le32(d: ByteArray, o: Int) = (d[o].toLong() and 0xff) or ((d[o + 1].toLong() and 0xff) shl 8) or ((d[o + 2].toLong() and 0xff) shl 16) or ((d[o + 3].toLong() and 0xff) shl 24)
    fun cmdOf(pkt: ByteArray) = le16(pkt, 1)

    /**
     * Die Seriennummer aus den Herstellerdaten: Großbuchstaben-Hex, beginnt mit dem Modellcode (881 Note Pro, 888 Note,
     * 880/882 Pin, 860 One). Aufbau [project len][project][L][version][S][serial]; sonst Suche nach 8 Byte.
     * Android liefert die Herstellerdaten ohne die Firmen-ID davor; der Aufrufer setzt sie wieder vorn an.
     */
    fun serial(manufacturerData: ByteArray): String? {
        val models = listOf("881", "888", "880", "882", "860")
        val b = manufacturerData
        if (b.size > 4) {
            val vAt = 3 + (b[2].toInt() and 0xff)
            if (vAt < b.size) {
                val sAt = vAt + 1 + (b[vAt].toInt() and 0xff)
                if (sAt < b.size) {
                    val sl = b[sAt].toInt() and 0xff
                    if (sl in 8..10 && sAt + 1 + sl <= b.size) {
                        val s = b.copyOfRange(sAt + 1, sAt + 1 + sl).joinToString("") { "%02X".format(it) }
                        if (models.any { s.startsWith(it) }) return s
                    }
                }
            }
        }
        val hex = b.joinToString("") { "%02X".format(it) }
        var i = 0
        while (i + 16 <= hex.length) {
            val window = hex.substring(i, i + 16)
            if (models.any { window.startsWith(it) }) return window
            i += 2
        }
        return null
    }
}

/** iOS: `PlaudSession` — verschlüsselte Protokoll-20-Sitzung: ChaCha20-Poly1305 über (seq u32 ‖ Paket), feste Nonce und AAD. */
class PlaudSession(private val key: ByteArray, private val nonce: ByteArray, private val aad: ByteArray) {
    private var txSeq = 1L // das erste gesendete Paket trägt 2
    private var rxSeq = -1L

    @Synchronized fun seal(plain: ByteArray): ByteArray {
        txSeq = (txSeq + 1) and 0xffffffffL
        return PlaudCrypto.aeadSeal(PlaudProto.u32le(txSeq) + plain, key, nonce, aad)
    }

    /** Das innere Paket, oder null bei Wiederholung oder fehlgeschlagener Prüfung. */
    @Synchronized fun open(data: ByteArray): ByteArray? {
        val plain = PlaudCrypto.aeadOpen(data, key, nonce, aad) ?: return null
        if (plain.size < 4) return null
        val seq = PlaudProto.le32(plain, 0)
        if (seq <= rxSeq) return null
        rxSeq = seq
        return plain.copyOfRange(4, plain.size)
    }
}

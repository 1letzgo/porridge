// Ported from roopen219/plaude-archiver (MIT License, https://github.com/roopen219/plaude-archiver):
// the Plaud Note Pro Bluetooth protocol and file format, reverse-engineered there.
package de.letzgo.porridge.plaud

import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class PlaudCryptoException(message: String) : Exception(message)

/** iOS: `PlaudCrypto` (Services/Plaud/PlaudCrypto.swift). */
object PlaudCrypto {
    fun base64urlDecode(s: String): ByteArray? {
        var t = s.replace('-', '+').replace('_', '/')
        while (t.length % 4 != 0) t += "="
        return runCatching { Base64.getDecoder().decode(t) }.getOrNull()
    }

    // Fernet (x-encrypt-response: 1). Schlüssel aus der Plaud-App (Klasse wng): HMAC [0:16], AES [16:32].
    val fernetKey: ByteArray = base64urlDecode("8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=")!!

    fun fernetDecrypt(token: String): ByteArray {
        val raw = base64urlDecode(token.trim()) ?: throw PlaudCryptoException("Fernet: bad base64")
        if (raw.size < 73 || raw[0] != 0x80.toByte()) throw PlaudCryptoException("Fernet: bad version/length")
        val body = raw.copyOfRange(0, raw.size - 32)
        val mac = raw.copyOfRange(raw.size - 32, raw.size)
        val hmac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(fernetKey.copyOfRange(0, 16), "HmacSHA256")) }.doFinal(body)
        if (!java.security.MessageDigest.isEqual(hmac, mac)) throw PlaudCryptoException("Fernet: HMAC check failed")
        val iv = raw.copyOfRange(9, 25)
        val ct = raw.copyOfRange(25, raw.size - 32)
        return Cipher.getInstance("AES/CBC/PKCS5Padding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(fernetKey.copyOfRange(16, 32), "AES"), IvParameterSpec(iv))
            doFinal(ct)
        }
    }

    /** Für Tests: ein Fernet-Token mit dem Plaud-Schlüssel. */
    internal fun fernetEncrypt(plain: ByteArray, iv: ByteArray, time: Long = 0): String {
        val ct = Cipher.getInstance("AES/CBC/PKCS5Padding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(fernetKey.copyOfRange(16, 32), "AES"), IvParameterSpec(iv))
            doFinal(plain)
        }
        val body = byteArrayOf(0x80.toByte()) + ByteArray(8) { ((time shr (56 - 8 * it)) and 0xff).toByte() } + iv + ct
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(fernetKey.copyOfRange(0, 16), "HmacSHA256")) }.doFinal(body)
        return Base64.getUrlEncoder().encodeToString(body + mac)
    }

    // RSA: der private Schlüssel aus gen_key (PKCS#8-PEM); PKCS#1-v1.5-Entschlüsselung.
    fun importRSAPrivateKey(pem: String): PrivateKey {
        val b64 = pem.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "")
            .replace("-----BEGIN RSA PRIVATE KEY-----", "").replace("-----END RSA PRIVATE KEY-----", "")
            .filter { !it.isWhitespace() }
        val der = runCatching { Base64.getDecoder().decode(b64) }.getOrNull() ?: throw PlaudCryptoException("RSA: bad PEM base64")
        // Android liest PKCS#8 direkt; ein PKCS#1-Schlüssel wird in PKCS#8 verpackt.
        val pkcs8 = if (pem.contains("RSA PRIVATE KEY")) wrapPKCS1(der) else der
        return runCatching { KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(pkcs8)) }
            .getOrElse { throw PlaudCryptoException("RSA import failed: ${it.message}") }
    }

    private fun wrapPKCS1(pkcs1: ByteArray): ByteArray {
        fun len(n: Int): ByteArray = if (n < 128) byteArrayOf(n.toByte()) else {
            val bytes = generateSequence(n) { it shr 8 }.takeWhile { it > 0 }.map { (it and 0xff).toByte() }.toList().reversed()
            byteArrayOf((0x80 or bytes.size).toByte()) + bytes.toByteArray()
        }
        val algorithm = byteArrayOf(0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(), 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00)
        val octet = byteArrayOf(0x04) + len(pkcs1.size) + pkcs1
        val inner = byteArrayOf(0x02, 0x01, 0x00) + algorithm + octet
        return byteArrayOf(0x30) + len(inner.size) + inner
    }

    fun rsaDecryptPKCS1(cipher: ByteArray, key: PrivateKey): ByteArray =
        runCatching { Cipher.getInstance("RSA/ECB/PKCS1Padding").run { init(Cipher.DECRYPT_MODE, key); doFinal(cipher) } }
            .getOrElse { throw PlaudCryptoException("RSA decrypt failed: ${it.message}") }

    // ChaCha20 (RFC 8439): 32-Byte-Schlüssel, 12-Byte-Nonce, 32-Bit-Blockzähler.

    private fun rotl(x: Int, n: Int) = (x shl n) or (x ushr (32 - n))

    private fun quarterRound(s: IntArray, a: Int, b: Int, c: Int, d: Int) {
        s[a] += s[b]; s[d] = rotl(s[d] xor s[a], 16)
        s[c] += s[d]; s[b] = rotl(s[b] xor s[c], 12)
        s[a] += s[b]; s[d] = rotl(s[d] xor s[a], 8)
        s[c] += s[d]; s[b] = rotl(s[b] xor s[c], 7)
    }

    private fun words(d: ByteArray): IntArray = IntArray(d.size / 4) { i ->
        (d[i * 4].toInt() and 0xff) or ((d[i * 4 + 1].toInt() and 0xff) shl 8) or ((d[i * 4 + 2].toInt() and 0xff) shl 16) or ((d[i * 4 + 3].toInt() and 0xff) shl 24)
    }

    internal fun chachaBlock(key: IntArray, counter: Int, nonce: IntArray): ByteArray {
        val state = IntArray(16)
        state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574
        for (i in 0 until 8) state[4 + i] = key[i]
        state[12] = counter
        for (i in 0 until 3) state[13 + i] = nonce[i]
        val w = state.copyOf()
        repeat(10) {
            quarterRound(w, 0, 4, 8, 12); quarterRound(w, 1, 5, 9, 13); quarterRound(w, 2, 6, 10, 14); quarterRound(w, 3, 7, 11, 15)
            quarterRound(w, 0, 5, 10, 15); quarterRound(w, 1, 6, 11, 12); quarterRound(w, 2, 7, 8, 13); quarterRound(w, 3, 4, 9, 14)
        }
        val out = ByteArray(64)
        for (i in 0 until 16) {
            val v = w[i] + state[i]
            out[i * 4] = v.toByte(); out[i * 4 + 1] = (v ushr 8).toByte(); out[i * 4 + 2] = (v ushr 16).toByte(); out[i * 4 + 3] = (v ushr 24).toByte()
        }
        return out
    }

    fun chacha20(data: ByteArray, key: ByteArray, nonce: ByteArray, counter: Int): ByteArray {
        val k = words(key)
        val n = words(nonce)
        val out = ByteArray(data.size)
        var block = counter
        var off = 0
        while (off < data.size) {
            val ks = chachaBlock(k, block, n)
            val end = minOf(64, data.size - off)
            for (i in 0 until end) out[off + i] = (data[off + i].toInt() xor ks[i].toInt()).toByte()
            off += end
            block++
        }
        return out
    }

    // ChaCha20-Poly1305 (RFC 8439, Abschnitt 2.8). Android bietet die Chiffre erst ab API 28; die App läuft ab 26.

    private fun poly1305(key: ByteArray, message: ByteArray): ByteArray {
        val r = java.math.BigInteger(1, key.copyOfRange(0, 16).reversedArray()).and(java.math.BigInteger("0ffffffc0ffffffc0ffffffc0fffffff", 16))
        val s = java.math.BigInteger(1, key.copyOfRange(16, 32).reversedArray())
        val p = java.math.BigInteger.ONE.shiftLeft(130).subtract(java.math.BigInteger.valueOf(5))
        var acc = java.math.BigInteger.ZERO
        var i = 0
        while (i < message.size) {
            val end = minOf(i + 16, message.size)
            val block = message.copyOfRange(i, end) + byteArrayOf(1)
            acc = acc.add(java.math.BigInteger(1, block.reversedArray())).multiply(r).mod(p)
            i = end
        }
        val tag = acc.add(s).toByteArray().reversedArray()
        return ByteArray(16) { if (it < tag.size) tag[it] else 0 }
    }

    private fun pad16(n: Int) = ByteArray((16 - n % 16) % 16)
    private fun le64(v: Long) = ByteArray(8) { (v ushr (8 * it)).toByte() }

    private fun macData(aad: ByteArray, ct: ByteArray) = aad + pad16(aad.size) + ct + pad16(ct.size) + le64(aad.size.toLong()) + le64(ct.size.toLong())

    /** Verschlüsselt: ciphertext ‖ tag (16 Byte). */
    fun aeadSeal(plain: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        val polyKey = chachaBlock(words(key), 0, words(nonce)).copyOfRange(0, 32)
        val ct = chacha20(plain, key, nonce, 1)
        return ct + poly1305(polyKey, macData(aad, ct))
    }

    /** Entschlüsselt ciphertext ‖ tag; null, wenn die Prüfung fehlschlägt. */
    fun aeadOpen(sealed: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray? {
        if (sealed.size < 16) return null
        val ct = sealed.copyOfRange(0, sealed.size - 16)
        val tag = sealed.copyOfRange(sealed.size - 16, sealed.size)
        val polyKey = chachaBlock(words(key), 0, words(nonce)).copyOfRange(0, 32)
        if (!java.security.MessageDigest.isEqual(poly1305(polyKey, macData(aad, ct)), tag)) return null
        return chacha20(ct, key, nonce, 1)
    }

    // Eine ganze Aufnahmedatei („PLAUD.AI“, Version 1) → Ogg Opus.

    fun decryptRecordingFile(data: ByteArray, privateKey: PrivateKey): ByteArray {
        if (data.size < 512 || !data.copyOfRange(0, 8).contentEquals("PLAUD.AI".toByteArray())) throw PlaudCryptoException("not a PLAUD.AI file")
        fun u16(off: Int) = (data[off].toInt() and 0xff) or ((data[off + 1].toInt() and 0xff) shl 8)
        fun u32(off: Int) = (data[off].toInt() and 0xff) or ((data[off + 1].toInt() and 0xff) shl 8) or ((data[off + 2].toInt() and 0xff) shl 16) or ((data[off + 3].toInt() and 0xff) shl 24)
        val version = u16(8)
        if (version != 1) throw PlaudCryptoException("header version $version not supported (version 2 = ECDH, protocol 30)")
        val headerSize = u16(10)
        if (headerSize < 512 || headerSize > data.size) throw PlaudCryptoException("bad header size $headerSize")
        val counter = u32(128)
        val nonce = data.copyOfRange(132, 144)
        var contentKey = rsaDecryptPKCS1(data.copyOfRange(256, 512), privateKey)
        if (contentKey.size > 32) contentKey = contentKey.copyOfRange(contentKey.size - 32, contentKey.size) // Firmware-Eigenheit
        if (contentKey.size != 32) throw PlaudCryptoException("content key wrong length")
        return decryptBody(data.copyOfRange(headerSize, data.size), contentKey, nonce, counter, u32(144))
    }

    /**
     * Zwei Körper-Layouts, nach der Segmentgröße im Header (u32 bei 144): 0 (Note Pro) ein ChaCha20-Strom ab dem
     * Header-Zähler, das Ergebnis ist Ogg; > 0 (das ursprüngliche Note: 80) jedes Segment für sich mit Zähler 0, das
     * Ergebnis sind nackte Opus-Rahmen, hier in Ogg verpackt. (bitboxx in roopen219/plaude-archiver#1)
     */
    fun decryptBody(body: ByteArray, key: ByteArray, nonce: ByteArray, counter: Int, segmentSize: Int): ByteArray {
        if (segmentSize <= 0) return chacha20(body, key, nonce, counter)
        if (segmentSize > 4096) throw PlaudCryptoException("segment size $segmentSize not supported")
        val clear = java.io.ByteArrayOutputStream(body.size)
        var off = 0
        while (off < body.size) {
            val end = minOf(off + segmentSize, body.size)
            clear.write(chacha20(body.copyOfRange(off, end), key, nonce, 0))
            off = end
        }
        val bytes = clear.toByteArray()
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals("OggS".toByteArray())) return bytes
        if (!opusFramesLookValid(bytes, segmentSize)) throw PlaudCryptoException("the decrypted audio is not Opus frames; the key or the segment layout is wrong")
        return PlaudOggOpus.wrap(bytes, segmentSize)
    }

    /** Prüfung der offiziellen App für nackte Rahmen: Rahmen ungleich null beginnen mit Opus-TOC 0xB8/0xB9 (bis auf weniger als 5). */
    fun opusFramesLookValid(data: ByteArray, frameBytes: Int): Boolean {
        if (frameBytes <= 0 || data.size < frameBytes) return false
        var nonZero = 0
        var valid = 0
        var i = 0
        while (i + frameBytes <= data.size) {
            if ((i until i + frameBytes).any { data[it] != 0.toByte() }) {
                nonZero++
                val toc = data[i].toInt() and 0xff
                if (toc == 0xB8 || toc == 0xB9) valid++
            }
            i += frameBytes
        }
        return nonZero > 0 && nonZero - valid < 5
    }

    /**
     * Ob `data` ein ganzer Ogg-Strom ist: Seiten lückenlos, jede CRC stimmt, die letzte als Ende markiert. ChaCha20 hat
     * keinen Prüfwert; das ist die Prüfung, dass die lokale Kopie heil ist.
     */
    fun isCompleteOgg(data: ByteArray): Boolean {
        var i = 0
        var lastHeaderType = 0
        while (i < data.size) {
            if (i + 27 > data.size || data[i] != 0x4F.toByte() || data[i + 1] != 0x67.toByte() || data[i + 2] != 0x67.toByte() || data[i + 3] != 0x53.toByte()) return false
            val segments = data[i + 26].toInt() and 0xff
            if (i + 27 + segments > data.size) return false
            var body = 0
            for (k in 0 until segments) body += data[i + 27 + k].toInt() and 0xff
            val size = 27 + segments + body
            if (i + size > data.size) return false
            val stored = (data[i + 22].toLong() and 0xff) or ((data[i + 23].toLong() and 0xff) shl 8) or ((data[i + 24].toLong() and 0xff) shl 16) or ((data[i + 25].toLong() and 0xff) shl 24)
            var crc = 0L
            for (k in i until i + size) {
                val byte = if (k in (i + 22) until (i + 26)) 0 else data[k].toInt() and 0xff
                crc = ((crc shl 8) xor OGG_CRC[(((crc ushr 24) xor byte.toLong()) and 0xff).toInt()]) and 0xffffffffL
            }
            if (crc != stored) return false
            lastHeaderType = data[i + 5].toInt()
            i += size
        }
        return data.isNotEmpty() && (lastHeaderType and 0x04) != 0
    }

    internal val OGG_CRC: LongArray = LongArray(256) { n ->
        var c = n.toLong() shl 24
        repeat(8) { c = if (c and 0x80000000L != 0L) ((c shl 1) xor 0x04C11DB7L) and 0xffffffffL else (c shl 1) and 0xffffffffL }
        c
    }
}

/** Verpackt die nackten Opus-Rahmen des ursprünglichen Note (CELT wideband, 20 ms, mono) in Ogg Opus. */
object PlaudOggOpus {
    private fun le(v: Long, n: Int) = ByteArray(n) { (v ushr (8 * it)).toByte() }

    private fun page(serial: Long, seq: Long, granule: Long, packets: List<ByteArray>, type: Int): ByteArray {
        val lacing = mutableListOf<Byte>()
        for (p in packets) { repeat(p.size / 255) { lacing += 255.toByte() }; lacing += (p.size % 255).toByte() }
        val out = java.io.ByteArrayOutputStream()
        out.write("OggS".toByteArray()); out.write(0); out.write(type)
        out.write(le(granule, 8)); out.write(le(serial, 4)); out.write(le(seq, 4))
        out.write(byteArrayOf(0, 0, 0, 0)); out.write(lacing.size)
        out.write(lacing.toByteArray())
        for (p in packets) out.write(p)
        val bytes = out.toByteArray()
        var crc = 0L
        for (b in bytes) crc = ((crc shl 8) xor PlaudCrypto.OGG_CRC[(((crc ushr 24) xor (b.toLong() and 0xff)) and 0xff).toInt()]) and 0xffffffffL
        System.arraycopy(le(crc, 4), 0, bytes, 22, 4)
        return bytes
    }

    fun wrap(raw: ByteArray, frameBytes: Int = 80, inputRate: Long = 16_000): ByteArray {
        val frames = (0..raw.size - frameBytes step frameBytes).map { raw.copyOfRange(it, it + frameBytes) }
        val serial = 0x504C4144L
        val head = "OpusHead".toByteArray() + byteArrayOf(1, 1) + le(312, 2) + le(inputRate, 4) + byteArrayOf(0, 0, 0)
        val tags = "OpusTags".toByteArray() + le(6, 4) + "plaude".toByteArray() + le(0, 4)
        val out = java.io.ByteArrayOutputStream()
        out.write(page(serial, 0, 0, listOf(head), 0x02))
        out.write(page(serial, 1, 0, listOf(tags), 0x00))
        var seq = 2L
        var granule = 0L
        var i = 0
        while (i < frames.size) {
            val chunk = frames.subList(i, minOf(i + 50, frames.size))
            granule += 960L * chunk.size // 20 ms bei 48 kHz je Rahmen
            out.write(page(serial, seq, granule, chunk, if (i + 50 >= frames.size) 0x04 else 0x00))
            seq++
            i += 50
        }
        return out.toByteArray()
    }
}

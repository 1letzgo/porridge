package de.letzgo.porridge.plaud

import android.media.MediaCodec
import android.media.MediaFormat
import de.letzgo.porridge.audio.AacWriter
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * iOS: `OpusOggDecoder` — macht aus einer Ogg-Opus-Aufnahme eine AAC-m4a-Datei, die der Rest der App liest.
 * Den Ogg-Container liest dieser Code; Opus-Pakete dekodiert `MediaCodec` (seit Android 5 an Bord).
 */
object OpusOggDecoder {
    class Stream(val channels: Int, val preSkip: Int, val head: ByteArray, val packets: List<ByteArray>)

    /** Die Opus-Pakete einer Ogg-Datei (ohne die zwei Kopfpakete). */
    fun demux(data: ByteArray): Stream {
        var channels = 1
        var preSkip = 0
        var head = ByteArray(0)
        val packets = mutableListOf<ByteArray>()
        val current = java.io.ByteArrayOutputStream()
        var index = 0
        var packetNumber = 0
        while (index + 27 <= data.size) {
            if (!(data[index] == 0x4F.toByte() && data[index + 1] == 0x67.toByte() && data[index + 2] == 0x67.toByte() && data[index + 3] == 0x53.toByte())) error("damaged Ogg page")
            val segments = data[index + 26].toInt() and 0xff
            if (index + 27 + segments > data.size) error("truncated Ogg page")
            var offset = index + 27 + segments
            for (s in 0 until segments) {
                val length = data[index + 27 + s].toInt() and 0xff
                if (offset + length > data.size) error("truncated Ogg page")
                current.write(data, offset, length)
                offset += length
                if (length < 255) {
                    val packet = current.toByteArray()
                    when (packetNumber) {
                        0 -> {
                            if (packet.size < 19 || String(packet, 0, 8) != "OpusHead") error("not Opus audio")
                            channels = (packet[9].toInt() and 0xff).coerceIn(1, 2)
                            preSkip = (packet[10].toInt() and 0xff) or ((packet[11].toInt() and 0xff) shl 8)
                            head = packet
                        }
                        1 -> Unit
                        else -> packets += packet
                    }
                    packetNumber++
                    current.reset()
                }
            }
            index = offset
        }
        if (packets.isEmpty()) error("no audio in the file")
        return Stream(channels, preSkip, head, packets)
    }

    /**
     * Ob libopus dieses Paket annimmt (RFC 6716 §3.2, wie `opus_packet_parse`). Der Decoder in Android bricht beim
     * ersten ungültigen Paket die ganze Aufnahme ab; in `roopen219/plaude-archiver` lässt auch die Prüfung der offiziellen
     * App einzelne schlechte Rahmen durch.
     */
    fun isValidPacket(p: ByteArray): Boolean {
        if (p.isEmpty()) return false
        val toc = p[0].toInt() and 0xff
        val samples = when {
            toc and 0x80 != 0 -> 120 shl ((toc shr 3) and 3)
            toc and 0x60 == 0x60 -> if (toc and 0x08 != 0) 480 else 240
            (toc shr 3) and 3 == 3 -> 2880
            else -> 480 shl ((toc shr 3) and 3)
        }
        var at = 1
        var left = p.size - 1
        // Länge eines Rahmens: ein oder zwei Bytes; -1, wenn sie fehlen. Liefert die Länge, `at`/`left` rücken vor.
        fun frameLength(): Int {
            if (left < 1) return -1
            val first = p[at].toInt() and 0xff
            if (first < 252) { at += 1; left -= 1; return first }
            if (left < 2) return -1
            val length = (p[at + 1].toInt() and 0xff) * 4 + first
            at += 2; left -= 2
            return length
        }
        val last: Int
        when (toc and 3) {
            0 -> last = left
            1 -> { if (left % 2 != 0) return false; last = left / 2 }
            2 -> {
                val first = frameLength()
                if (first < 0 || first > left) return false
                last = left - first
            }
            else -> {
                if (left < 1) return false
                val header = p[at].toInt() and 0xff
                at += 1; left -= 1
                val count = header and 0x3f
                if (count == 0 || samples * count > 5760) return false
                if (header and 0x40 != 0) {
                    while (true) {
                        if (left < 1) return false
                        val padding = p[at].toInt() and 0xff
                        at += 1; left -= 1
                        left -= if (padding == 255) 254 else padding
                        if (left < 0) return false
                        if (padding != 255) break
                    }
                }
                if (header and 0x80 == 0) {
                    if (left % count != 0) return false
                    last = left / count
                } else {
                    var rest = left
                    for (i in 0 until count - 1) {
                        val before = left
                        val length = frameLength()
                        if (length < 0) return false
                        rest -= (before - left) + length
                        if (rest < 0) return false
                    }
                    last = rest
                }
            }
        }
        return last <= 1275
    }

    /**
     * Ersetzt ungültige Pakete durch ein leeres der gleichen Art: Der Decoder überbrückt die Stelle, und die Zeit
     * danach stimmt weiter. Sind es zu viele, ist die Datei kaputt, und aus ihr soll keine Notiz werden.
     */
    fun repaired(packets: List<ByteArray>): List<ByteArray> {
        val invalid = packets.count { !isValidPacket(it) }
        if (invalid == 0) return packets
        PlaudLog.log("opus: replaced $invalid of ${packets.size} invalid packets")
        if (invalid >= maxOf(5, packets.size / 100)) error("too many damaged audio packets")
        val filler = packets.firstOrNull(::isValidPacket)?.let { byteArrayOf((it[0].toInt() and 0xfc).toByte()) } ?: error("no valid audio packets")
        return packets.map { if (isValidPacket(it)) it else filler }
    }

    private fun le64(v: Long) = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).array()

    /** Schreibt das dekodierte Audio als AAC nach [target]; liefert die Dauer in Sekunden. */
    fun decode(ogg: ByteArray, target: File): Double {
        val stream = demux(ogg)
        val packets = repaired(stream.packets)
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48_000, stream.channels).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(stream.head))
            setByteBuffer("csd-1", ByteBuffer.wrap(le64(stream.preSkip * 1_000_000_000L / 48_000)))
            setByteBuffer("csd-2", ByteBuffer.wrap(le64(80_000_000L)))
        }
        val codec = runCatching { MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS) }.getOrElse { error("this phone cannot decode Opus") }
        codec.configure(format, null, null, 0)
        codec.start()
        target.delete()
        val writer = AacWriter(target, 48_000, stream.channels)
        val info = MediaCodec.BufferInfo()
        var next = 0
        var time = 0L
        var inputDone = false
        var failed = false
        try {
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        if (next < packets.size) {
                            val packet = packets[next++]
                            codec.getInputBuffer(i)!!.apply { clear(); put(packet) }
                            codec.queueInputBuffer(i, 0, packet.size, time, 0)
                            time += 20_000
                        } else {
                            codec.queueInputBuffer(i, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o >= 0) {
                    val buffer = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset); buffer.limit(info.offset + info.size)
                    val shorts = buffer.asShortBuffer()
                    val pcm = ShortArray(shorts.remaining()).also { shorts.get(it) }
                    if (pcm.isNotEmpty()) writer.write(pcm, pcm.size)
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } catch (e: IllegalStateException) {
            // Der Decoder gibt nur seinen Zustand an („Pending dequeue…“); damit kann niemand etwas anfangen.
            PlaudLog.log("opus: decoder failed at packet $next of ${packets.size}: $e")
            failed = true
            error("this recording could not be converted")
        } finally {
            runCatching { codec.stop() }
            codec.release()
            writer.close()
            if (failed) target.delete()
        }
        return writer.duration
    }
}

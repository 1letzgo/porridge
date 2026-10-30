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

    private fun le64(v: Long) = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).array()

    /** Schreibt das dekodierte Audio als AAC nach [target]; liefert die Dauer in Sekunden. */
    fun decode(ogg: ByteArray, target: File): Double {
        val stream = demux(ogg)
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
        try {
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        if (next < stream.packets.size) {
                            val packet = stream.packets[next++]
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
        } finally {
            runCatching { codec.stop() }
            codec.release()
            writer.close()
        }
        return writer.duration
    }
}

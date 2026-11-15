package de.letzgo.porridge.audio

import de.letzgo.porridge.logic.ChannelEnergy
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.nio.channels.FileChannel

/**
 * iOS: `PreparedAudio` — die 16-kHz-Mono-Spur für Erkennung und Diarisierung. Wie auf iOS (`monoURL`) liegt sie in einer
 * Datei und nicht im Speicher der App: Zwei Stunden sind 230 MB, mehr als Android einer App an Speicher gibt. Wer sie
 * hat, schließt sie ([close] löscht die Datei).
 */
class PreparedAudio internal constructor(private val file: File, val size: Int, val duration: Double, val channelEnergy: ChannelEnergy?) : Closeable {
    private val access = RandomAccessFile(file, "r")
    private val samples: ShortBuffer =
        if (size == 0) ShortBuffer.allocate(0)
        else access.channel.map(FileChannel.MapMode.READ_ONLY, 0, size * 2L).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()

    operator fun get(index: Int): Float = samples.get(index) / 32768f

    /** Ein Abschnitt als Float, für das Sprachmodell. */
    fun slice(from: Int, to: Int): FloatArray = FloatArray(to - from) { samples.get(from + it) / 32768f }

    /** Alle Samples als Float (die Diarisierung will sie am Stück). */
    fun floats(): FloatArray = slice(0, size)

    override fun close() {
        runCatching { access.close() }
        file.delete()
    }
}

/** iOS: `AudioPreprocessor` — liest die Aufnahme einmal: Mono-Mix auf 16 kHz und, bei getrenntem Stereo, die Energie beider Kanäle. */
object AudioPreprocessor {
    const val ENERGY_FRAME_DURATION = 0.05
    const val TARGET_RATE = 16_000

    fun prepare(source: File, measureChannels: Boolean): PreparedAudio {
        var resampler: Resampler? = null
        var sampleRate = 0
        // Reste eines beendeten Prozesses; eine laufende Vorbereitung ist nie so alt.
        File(System.getProperty("java.io.tmpdir") ?: ".").listFiles { f -> f.name.startsWith(TEMP_PREFIX) && System.currentTimeMillis() - f.lastModified() > 24 * 3_600_000L }?.forEach { it.delete() }
        val file = File.createTempFile(TEMP_PREFIX, ".pcm")
        var outCount = 0
        var totalFrames = 0L
        val left = FloatList()
        val right = FloatList()
        var accLeft = 0f
        var accRight = 0f
        var accCount = 0
        var frameLength = 1
        var measure = false

        try {
        BufferedOutputStream(file.outputStream(), 64 * 1024).use { out ->
        AudioDecoder.decode(source, onInfo = { info ->
            if (resampler == null || info.sampleRate != sampleRate) {
                sampleRate = info.sampleRate
                resampler = Resampler(sampleRate, TARGET_RATE)
                frameLength = maxOf(1, (sampleRate * ENERGY_FRAME_DURATION).toInt())
            }
            measure = measureChannels && info.channels >= 2
        }) { block, channels ->
            val frames = block.size / channels
            totalFrames += frames
            val mono = FloatArray(frames)
            for (f in 0 until frames) {
                var sum = 0f
                for (c in 0 until channels) sum += block[f * channels + c]
                mono[f] = sum / channels
                if (measure) {
                    val l = block[f * channels]
                    val r = block[f * channels + 1]
                    accLeft += l * l
                    accRight += r * r
                    if (++accCount == frameLength) {
                        left.add(accLeft / frameLength); right.add(accRight / frameLength)
                        accLeft = 0f; accRight = 0f; accCount = 0
                    }
                }
            }
            val resampled = resampler!!.process(mono)
            val bytes = ByteArray(resampled.size * 2)
            for ((i, s) in resampled.withIndex()) {
                val value = (s.coerceIn(-1f, 1f) * 32767f).toInt()
                bytes[i * 2] = value.toByte()
                bytes[i * 2 + 1] = (value shr 8).toByte()
            }
            out.write(bytes)
            outCount += resampled.size
        }
        }
        if (measure && accCount > 0) {
            left.add(accLeft / accCount); right.add(accRight / accCount)
        }
        if (sampleRate == 0) error("This audio format is not supported.")
        return PreparedAudio(
            file, outCount,
            duration = totalFrames.toDouble() / sampleRate,
            channelEnergy = if (measure) ChannelEnergy(frameLength.toDouble() / sampleRate, left.toArray(), right.toArray()) else null,
        )
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
    }

    private const val TEMP_PREFIX = "porridge-prepared-"
}

/** Wachsende Float-Liste ohne Boxing. */
class FloatList(capacity: Int = 1024) {
    private var data = FloatArray(capacity)
    var size = 0
        private set

    fun add(value: Float) {
        if (size == data.size) data = data.copyOf(data.size * 2)
        data[size++] = value
    }

    fun toArray(): FloatArray = data.copyOf(size)
}

package de.letzgo.porridge.audio

import de.letzgo.porridge.logic.ChannelEnergy
import java.io.File

/** iOS: `PreparedAudio` — die 16-kHz-Mono-Spur für Erkennung und Diarisierung, als 16-Bit-Samples im Speicher. */
class PreparedAudio(val pcm: ShortArray, val duration: Double, val channelEnergy: ChannelEnergy?) {
    /** Alle Samples als Float (für die Diarisierung). */
    fun floats(): FloatArray = FloatArray(pcm.size) { pcm[it] / 32768f }
}

/** iOS: `AudioPreprocessor` — liest die Aufnahme einmal: Mono-Mix auf 16 kHz und, bei getrenntem Stereo, die Energie beider Kanäle. */
object AudioPreprocessor {
    const val ENERGY_FRAME_DURATION = 0.05
    const val TARGET_RATE = 16_000

    fun prepare(source: File, measureChannels: Boolean): PreparedAudio {
        var resampler: Resampler? = null
        var sampleRate = 0
        var out = ShortArray(TARGET_RATE * 60)
        var outCount = 0
        var totalFrames = 0L
        val left = FloatList()
        val right = FloatList()
        var accLeft = 0f
        var accRight = 0f
        var accCount = 0
        var frameLength = 1
        var measure = false

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
            if (outCount + resampled.size > out.size) out = out.copyOf(maxOf(out.size * 2, outCount + resampled.size))
            for (s in resampled) out[outCount++] = (s.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
        }
        if (measure && accCount > 0) {
            left.add(accLeft / accCount); right.add(accRight / accCount)
        }
        if (sampleRate == 0) error("This audio format is not supported.")
        return PreparedAudio(
            pcm = out.copyOf(outCount),
            duration = totalFrames.toDouble() / sampleRate,
            channelEnergy = if (measure) ChannelEnergy(frameLength.toDouble() / sampleRate, left.toArray(), right.toArray()) else null,
        )
    }
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

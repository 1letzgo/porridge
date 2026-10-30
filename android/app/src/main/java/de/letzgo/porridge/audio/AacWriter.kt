package de.letzgo.porridge.audio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

/** Schreibt 16-Bit-PCM (verschränkt) als AAC in eine m4a-Datei (iOS: `AVAudioFile` mit `kAudioFormatMPEG4AAC`). */
class AacWriter(file: File, private val sampleRate: Int, private val channels: Int, bitRate: Int = 64_000 * channels) {
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var track = -1
    private var muxing = false
    private var framesWritten = 0L
    private val info = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384 * channels)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    /** `pcm[0 until count]`, Kanäle verschränkt. */
    fun write(pcm: ShortArray, count: Int) {
        var offset = 0
        while (offset < count) {
            val index = codec.dequeueInputBuffer(10_000)
            if (index < 0) { drain(false); continue }
            val buffer = codec.getInputBuffer(index)!!
            val n = minOf(buffer.capacity() / 2, count - offset) / channels * channels
            buffer.clear()
            buffer.asShortBuffer().put(pcm, offset, n)
            val time = framesWritten * 1_000_000L / sampleRate
            codec.queueInputBuffer(index, 0, n * 2, time, 0)
            framesWritten += n / channels
            offset += n
            drain(false)
        }
    }

    private fun drain(endOfStream: Boolean) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxing = true
                }
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && muxing) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /** Dauer des Geschriebenen in Sekunden. */
    val duration: Double get() = framesWritten.toDouble() / sampleRate

    fun close() {
        runCatching {
            val index = codec.dequeueInputBuffer(10_000)
            if (index >= 0) codec.queueInputBuffer(index, 0, 0, framesWritten * 1_000_000L / sampleRate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drain(true)
        }
        runCatching { codec.stop() }
        codec.release()
        runCatching { if (muxing) muxer.stop() }
        muxer.release()
    }
}

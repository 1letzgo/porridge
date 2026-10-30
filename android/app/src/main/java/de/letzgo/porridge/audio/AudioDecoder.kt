package de.letzgo.porridge.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteOrder

/** Entpackt die erste Tonspur einer Datei (m4a, mp3, ogg, Video …) blockweise zu Float-PCM, Kanäle verschränkt. */
object AudioDecoder {
    class Info(val sampleRate: Int, val channels: Int)

    fun decode(file: File, onInfo: (Info) -> Unit, onBlock: (FloatArray, Int) -> Unit) {
        val extractor = MediaExtractor()
        extractor.setDataSource(file.absolutePath)
        try {
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("This file has no audio.")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmFloat = false
            onInfo(Info(sampleRate, channels))
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            try {
                while (!outputDone) {
                    if (!inputDone) {
                        val index = codec.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = codec.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val out = codec.outputFormat
                            sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            pcmFloat = out.containsKey(MediaFormat.KEY_PCM_ENCODING) && out.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                            onInfo(Info(sampleRate, channels))
                        }
                        index >= 0 -> {
                            val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val block = if (pcmFloat) {
                                val floats = buffer.asFloatBuffer()
                                FloatArray(floats.remaining()).also { floats.get(it) }
                            } else {
                                val shorts = buffer.asShortBuffer()
                                FloatArray(shorts.remaining()) { shorts.get(it) / 32768f }
                            }
                            if (block.isNotEmpty()) onBlock(block, channels)
                            codec.releaseOutputBuffer(index, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        }
                    }
                }
            } finally {
                codec.stop()
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }
}

package de.letzgo.porridge.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import de.letzgo.porridge.store.AudioStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.log10
import kotlin.math.sqrt

/** iOS: `RecordingResult`. */
data class RecordingResult(val fileName: String, val duration: Double, val channelCount: Int, val inputName: String, val isSplitStereo: Boolean)

/**
 * iOS: `AudioRecorder` (Services/AudioRecorder.swift) — nimmt den aktuellen Eingang als AAC auf, bis zu zwei Kanäle.
 * Ein externes Mikrofon hat Vorrang; liefert es zwei Kanäle (DJI-Empfänger im Stereo-Modus), bleiben sie getrennt.
 */
class AudioRecorder(private val context: Context) {
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()
    private val _elapsed = MutableStateFlow(0.0)
    val elapsed: StateFlow<Double> = _elapsed.asStateFlow()
    /** Pegel je Kanal, 0…1 (iOS: -55…-5 dB). */
    private val _levels = MutableStateFlow(listOf(0f))
    val levels: StateFlow<List<Float>> = _levels.asStateFlow()
    var inputName = ""
        private set
    var channelCount = 1
        private set
    var isSplitStereo = false
        private set

    /** Bekommt eine 16-kHz-Mono-Kopie jedes Puffers (für das Live-Transkript). */
    var onMono16k: ((FloatArray) -> Unit)? = null
    /** Der Eingang ist weggefallen (Mikrofon abgezogen): die Aufnahme endet. */
    var onInterrupted: (() -> Unit)? = null

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var writer: AacWriter? = null
    private var fileName: String? = null
    @Volatile private var running = false
    private var device: AudioDeviceInfo? = null
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
            // Nur wenn das genutzte Mikrofon wirklich weg ist; andere Geräte ändern nichts.
            if (running && removed.any { it.id == device?.id }) onInterrupted?.invoke()
        }
    }

    fun hasPermission() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun start() {
        check(!running) { "Already recording." }
        if (!hasPermission()) error("Porridge needs access to the microphone.")
        val inputs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val external = inputs.firstOrNull { it.type in EXTERNAL_TYPES }
        val builtIn = inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
        device = external ?: builtIn
        val stereo = external != null && external.channelCounts.let { it.isEmpty() || it.any { c -> c >= 2 } }
        val sampleRate = (external ?: builtIn)?.sampleRates?.filter { it in 16_000..48_000 }?.maxOrNull() ?: 48_000

        fun open(channels: Int): AudioRecord? {
            val mask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
            val min = AudioRecord.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) return null
            val r = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(sampleRate).setChannelMask(mask).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(min * 4, sampleRate / 5 * channels * 2))
                .build()
            if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return null }
            device?.let { r.preferredDevice = it }
            return r
        }
        val recorder = (if (stereo) open(2) else null) ?: open(1) ?: error("The microphone could not be opened.")
        channelCount = recorder.channelCount
        isSplitStereo = channelCount == 2
        inputName = device?.productName?.toString()?.takeIf { it.isNotBlank() } ?: if (external != null) "External Microphone" else "Microphone"

        val name = AudioStore.newFileName()
        val aac = AacWriter(AudioStore.file(name), sampleRate, channelCount)
        record = recorder
        writer = aac
        fileName = name
        running = true
        _isRecording.value = true
        _elapsed.value = 0.0
        audioManager.registerAudioDeviceCallback(deviceCallback, Handler(Looper.getMainLooper()))
        recorder.startRecording()
        // Ein Gerät, das trotz Stereo-Anfrage nur Mono liefert, meldet das erst hier.
        thread = Thread({ loop(recorder, aac, sampleRate) }, "porridge-recorder").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    private fun loop(recorder: AudioRecord, aac: AacWriter, sampleRate: Int) {
        val channels = recorder.channelCount
        val buffer = ShortArray(sampleRate / 10 * channels)
        val resampler = Resampler(sampleRate, 16_000)
        while (running) {
            val n = recorder.read(buffer, 0, buffer.size)
            if (n <= 0) continue
            aac.write(buffer, n)
            _elapsed.value = aac.duration
            val frames = n / channels
            _levels.value = (0 until channels).map { c ->
                var sum = 0.0
                for (f in 0 until frames) { val s = buffer[f * channels + c] / 32768.0; sum += s * s }
                val db = 20 * log10(maxOf(sqrt(sum / maxOf(frames, 1)), 1e-6))
                ((db + 55) / 50).toFloat().coerceIn(0f, 1f)
            }
            onMono16k?.let { feed ->
                val mono = FloatArray(frames) { f ->
                    var sum = 0f
                    for (c in 0 until channels) sum += buffer[f * channels + c] / 32768f
                    sum / channels
                }
                feed(resampler.process(mono))
            }
        }
    }

    fun stop(): RecordingResult? {
        if (!running) return null
        running = false
        thread?.join(2000)
        thread = null
        runCatching { record?.stop() }
        record?.release()
        record = null
        val duration = writer?.duration ?: _elapsed.value
        writer?.close()
        writer = null
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        _isRecording.value = false
        _levels.value = listOf(0f)
        val name = fileName ?: return null
        fileName = null
        return RecordingResult(name, duration, channelCount, inputName, isSplitStereo)
    }

    fun cancel() {
        stop()?.let { AudioStore.delete(it.fileName) }
    }

    companion object {
        private val EXTERNAL_TYPES = setOf(
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}

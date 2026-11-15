package de.letzgo.porridge.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import de.letzgo.porridge.store.AudioStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** iOS: `AudioPlayback` (Services/AudioPlayback.swift) — Abspielen, Springen und Vor/Zurück in einer Aufnahme. */
class AudioPlayback(context: Context? = null) {
    // iOS regelt das über die Audio-Session: Ein Anruf oder eine andere App hält die Wiedergabe an.
    private val audioManager = context?.applicationContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(attributes)
        .setOnAudioFocusChangeListener { change ->
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) scope.launch { pause() }
        }
        .build()
    private var player: MediaPlayer? = null
    private var loaded: String? = null
    private var ticker: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main)

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    private val _currentTime = MutableStateFlow(0.0)
    val currentTime: StateFlow<Double> = _currentTime.asStateFlow()
    private val _duration = MutableStateFlow(0.0)
    val duration: StateFlow<Double> = _duration.asStateFlow()

    fun load(fileName: String) {
        if (loaded == fileName) return
        stop()
        val p = MediaPlayer()
        p.setAudioAttributes(attributes)
        p.setDataSource(AudioStore.file(fileName).absolutePath)
        p.prepare()
        p.setOnCompletionListener { _isPlaying.value = false; ticker?.cancel(); audioManager?.abandonAudioFocusRequest(focus) }
        player = p
        loaded = fileName
        _duration.value = p.duration / 1000.0
        _currentTime.value = 0.0
    }

    fun toggle() = if (_isPlaying.value) pause() else play()

    fun play() {
        val p = player ?: return
        // Läuft gerade ein Anruf, gibt es keinen Fokus: dann nicht hineinspielen.
        if (audioManager != null && audioManager.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return
        p.start()
        _isPlaying.value = true
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive) {
                _currentTime.value = p.currentPosition / 1000.0
                delay(200)
            }
        }
    }

    fun pause() {
        runCatching { player?.pause() }
        _isPlaying.value = false
        ticker?.cancel()
        audioManager?.abandonAudioFocusRequest(focus)
    }

    fun seek(seconds: Double) {
        val p = player ?: return
        val target = seconds.coerceIn(0.0, _duration.value)
        p.seekTo((target * 1000).toInt())
        _currentTime.value = target
    }

    fun skip(seconds: Double) = seek(_currentTime.value + seconds)

    fun stop() {
        ticker?.cancel()
        audioManager?.abandonAudioFocusRequest(focus)
        player?.release()
        player = null
        loaded = null
        _isPlaying.value = false
    }
}

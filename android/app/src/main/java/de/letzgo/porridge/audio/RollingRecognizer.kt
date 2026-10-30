package de.letzgo.porridge.audio

import de.letzgo.porridge.ml.SpeechRecognizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * iOS: `RollingRecognizer` — Live-Transkript aus dem Stapel-Modell: etwa jede Sekunde wird der Ton seit dem letzten
 * festen Punkt neu erkannt (Wörter erscheinen und verbessern sich beim Sprechen); wird das Stück lang, wird es an der
 * leisesten Stelle geschlossen und bleibt als bestätigter Text.
 */
class RollingRecognizer(
    private val recognizer: SpeechRecognizer,
    private val language: String?,
    private val onUpdate: (confirmed: String, volatile: String) -> Unit,
) {
    private val sampleRate = 16_000
    private val lock = Mutex()
    private var segment = FloatList(sampleRate * 12)
    private var confirmed = ""
    private var volatile = ""
    private var newSamples = 0
    @Volatile private var stopped = false
    @Volatile var paused = false
        set(value) {
            field = value
            if (value) synchronized(this) { segment = FloatList(sampleRate * 12); newSamples = 0 }
        }
    private var job: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Neu erkennen nach so viel neuem Ton (0,9 s). */
    private val decodeInterval = 14_400
    /** Ein Stück wird ab dieser Länge geschlossen. */
    private val commitLength = 10 * sampleRate
    private val minimumDecode = sampleRate

    fun start() {
        job = scope.launch {
            while (isActive) {
                delay(250)
                tick()
            }
        }
    }

    /** Fügt 16-kHz-Mono-Samples hinzu. */
    fun append(samples: FloatArray) {
        if (stopped || paused) return
        synchronized(this) {
            for (s in samples) segment.add(s)
            newSamples += samples.size
        }
    }

    private fun snapshot(): FloatArray = synchronized(this) { segment.toArray() }

    private suspend fun tick() = lock.withLock {
        if (stopped || paused || newSamples < decodeInterval || segment.size < minimumDecode / 2) return@withLock
        synchronized(this) { newSamples = 0 }
        val snapshot = snapshot()
        val text = decode(snapshot) ?: return@withLock
        if (stopped) return@withLock
        volatile = text
        if (snapshot.size >= commitLength) commit(snapshot)
        onUpdate(confirmed, volatile)
    }

    /** Schließt das Stück an seiner leisesten Stelle; was danach gesprochen wurde, bleibt offen. */
    private suspend fun commit(snapshot: FloatArray) {
        val cut = quietestCut(snapshot)
        if (cut <= sampleRate) return
        val text = decode(snapshot.copyOfRange(0, cut)) ?: return
        if (text.isNotEmpty()) confirmed = listOf(confirmed, text).filter { it.isNotEmpty() }.joinToString(" ")
        synchronized(this) {
            // Ton, der während der Erkennung kam, gehört zum neuen offenen Stück.
            val rest = segment.toArray()
            segment = FloatList(sampleRate * 12).also { list -> for (i in minOf(cut, rest.size) until rest.size) list.add(rest[i]) }
            newSamples = decodeInterval
        }
        volatile = ""
    }

    private fun quietestCut(samples: FloatArray): Int {
        val frame = sampleRate / 5 // 200 ms
        val from = maxOf(frame * 15, samples.size - sampleRate * 5) / frame * frame // nicht vor 3 s
        val to = samples.size - frame * 2
        if (to <= from) return samples.size
        var best = from
        var bestEnergy = Float.MAX_VALUE
        var start = from
        while (start + frame <= to) {
            var sum = 0f
            for (i in start until start + frame) sum += samples[i] * samples[i]
            if (sum < bestEnergy) { bestEnergy = sum; best = start + frame / 2 }
            start += frame / 2
        }
        return best
    }

    private suspend fun decode(samples: FloatArray): String? = runCatching {
        recognizer.transcribe(if (samples.size < minimumDecode) samples.copyOf(minimumDecode) else samples, language)
            .joinToString(" ") { it.text }.trim()
    }.getOrNull()

    /** Hält an und liefert den ganzen Text, mit dem letzten Stück Ton. */
    suspend fun finish(): String {
        stopped = true
        job?.cancel()
        return lock.withLock {
            val rest = snapshot()
            if (rest.size >= minimumDecode / 2) decode(rest)?.let { volatile = it }
            onUpdate(confirmed, volatile)
            listOf(confirmed, volatile).filter { it.isNotEmpty() }.joinToString(" ")
        }
    }

    fun cancel() {
        stopped = true
        job?.cancel()
    }
}

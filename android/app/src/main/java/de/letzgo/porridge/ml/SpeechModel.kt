package de.letzgo.porridge.ml

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import de.letzgo.porridge.model.Word
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * iOS: Parakeet-Teil von `TranscriptionEngine` (Services/TranscriptionEngine.swift). Parakeet TDT v3 (0.6B, int8)
 * über sherpa-onnx; lange Aufnahmen in Abschnitten von höchstens 25 s ([ChunkPlanner]). Die Sprache erkennt das
 * Modell selbst (25 europäische Sprachen); `language` wird wie auf iOS nur durchgereicht.
 */
object SpeechModel : SpeechRecognizer {
    private const val SAMPLE_RATE = 16_000
    private val mutex = Mutex()
    private var recognizer: OfflineRecognizer? = null

    val pack get() = ModelCatalog.parakeet

    /** Lädt das Modell herunter (falls nötig) und in den Speicher. */
    suspend fun ensure(progress: (Float) -> Unit = {}) {
        ModelManager.ensure(pack, progress) { load() }
    }

    private suspend fun load() = mutex.withLock {
        if (recognizer != null) return@withLock
        val root = ModelManager.root
        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80, dither = 0f),
            modelConfig = OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = pack.file(root, "encoder.int8.onnx").path,
                    decoder = pack.file(root, "decoder.int8.onnx").path,
                    joiner = pack.file(root, "joiner.int8.onnx").path,
                ),
                tokens = pack.file(root, "tokens.txt").path,
                numThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6),
                modelType = "nemo_transducer",
            ),
            decodingMethod = "greedy_search",
        )
        recognizer = withContext(Dispatchers.Default) { OfflineRecognizer(null, config) }
    }

    fun release() {
        recognizer?.release()
        recognizer = null
        ModelManager.markUnloaded(pack)
    }

    override suspend fun transcribe(samples: FloatArray, language: String?): List<Word> {
        ensure()
        return mutex.withLock {
            val recognizer = checkNotNull(recognizer)
            withContext(Dispatchers.Default) {
                val words = mutableListOf<Word>()
                for (range in ChunkPlanner.cuts(samples, SAMPLE_RATE)) {
                    // Sehr kurze Stücke füllt iOS auf eine Sekunde auf; das Modell braucht etwas Ton.
                    var chunk = samples.copyOfRange(range.first, range.last + 1)
                    if (chunk.size < SAMPLE_RATE) chunk = chunk.copyOf(SAMPLE_RATE)
                    val stream = recognizer.createStream()
                    try {
                        stream.acceptWaveform(chunk, SAMPLE_RATE)
                        recognizer.decode(stream)
                        val result = recognizer.getResult(stream)
                        words += WordTimingLogic.words(
                            result.tokens.toList(), result.timestamps.toList(), result.durations.toList(),
                            offset = range.first.toDouble() / SAMPLE_RATE,
                        )
                    } finally {
                        stream.release()
                    }
                }
                words
            }
        }
    }
}

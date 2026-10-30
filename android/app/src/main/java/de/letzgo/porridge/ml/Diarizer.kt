package de.letzgo.porridge.ml

import com.k2fsa.sherpa.onnx.FastClusteringConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarization
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarizationConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationModelConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationPyannoteModelConfig
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractor
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
import de.letzgo.porridge.logic.DiarizedSegment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * iOS: Diarisierungs-Teil von `TranscriptionEngine` (FluidAudio `OfflineDiarizerManager`): Sprecher in einer
 * einkanaligen Aufnahme (pyannote-Segmentierung + Sprecher-Einbettung, Clustering) und Stimmabdrücke für Zeitspannen.
 */
object Diarizer {
    private const val SAMPLE_RATE = 16_000
    private val mutex = Mutex()
    private var diarization: OfflineSpeakerDiarization? = null
    private var extractor: SpeakerEmbeddingExtractor? = null

    val pack get() = ModelCatalog.diarizer

    suspend fun ensure(progress: (Float) -> Unit = {}) {
        ModelManager.ensure(pack, progress) { load() }
    }

    private suspend fun load() = mutex.withLock {
        if (diarization != null) return@withLock
        val root = ModelManager.root
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
        val embedding = SpeakerEmbeddingExtractorConfig(model = pack.file(root, "embedding.onnx").path, numThreads = threads)
        withContext(Dispatchers.Default) {
            diarization = OfflineSpeakerDiarization(
                null,
                OfflineSpeakerDiarizationConfig(
                    segmentation = OfflineSpeakerSegmentationModelConfig(
                        pyannote = OfflineSpeakerSegmentationPyannoteModelConfig(model = pack.file(root, "segmentation.onnx").path),
                        numThreads = threads,
                    ),
                    embedding = embedding,
                    // Anzahl unbekannt: Schwelle wie in den sherpa-onnx-Beispielen.
                    clustering = FastClusteringConfig(numClusters = -1, threshold = 0.5f),
                    minDurationOn = 0.3f,
                    minDurationOff = 0.5f,
                ),
            )
            extractor = SpeakerEmbeddingExtractor(null, embedding)
        }
    }

    fun release() {
        diarization?.release()
        extractor?.release()
        diarization = null
        extractor = null
        ModelManager.markUnloaded(pack)
    }

    /** Sprecherabschnitte einer 16-kHz-Mono-Aufnahme; Kennungen „0“, „1“ … wie sherpa sie vergibt. */
    suspend fun diarize(samples: FloatArray): List<DiarizedSegment> {
        ensure()
        return mutex.withLock {
            val diarization = checkNotNull(diarization)
            withContext(Dispatchers.Default) {
                diarization.process(samples).map { DiarizedSegment(it.speaker.toString(), it.start.toDouble(), it.end.toDouble()) }
            }
        }
    }

    /** iOS: `embedSpans` — ein Stimmabdruck je Zeitspanne (Sekunden). */
    suspend fun embed(samples: FloatArray, spans: List<ClosedFloatingPointRange<Double>>): List<FloatArray> {
        if (spans.isEmpty()) return emptyList()
        ensure()
        return mutex.withLock {
            val extractor = checkNotNull(extractor)
            withContext(Dispatchers.Default) {
                spans.mapNotNull { span ->
                    val from = (span.start * SAMPLE_RATE).toInt().coerceIn(0, samples.size)
                    val to = (span.endInclusive * SAMPLE_RATE).toInt().coerceIn(from, samples.size)
                    if (to - from < SAMPLE_RATE) return@mapNotNull null
                    val stream = extractor.createStream()
                    try {
                        stream.acceptWaveform(samples.copyOfRange(from, to), SAMPLE_RATE)
                        stream.inputFinished()
                        if (extractor.isReady(stream)) extractor.compute(stream) else null
                    } finally {
                        stream.release()
                    }
                }
            }
        }
    }
}

package de.letzgo.porridge.ml

import android.app.ActivityManager
import android.content.Context
import java.io.File

/** Eine Modelldatei zum Laden: Adresse, Name auf dem Gerät, Prüfsumme (wenn bekannt) und Größe. */
data class ModelFile(val url: String, val name: String, val sha256: String?, val bytes: Long)

/**
 * Ein Paket aus Modelldateien in einem eigenen Ordner (`filesDir/Models/<id>`). iOS lädt über FluidAudio bzw.
 * swift-huggingface; hier direkt von Hugging Face.
 */
data class ModelPack(val id: String, val displayName: String, val files: List<ModelFile>) {
    val bytes: Long get() = files.sumOf { it.bytes }
    val sizeText: String get() = if (bytes >= 1_000_000_000) "approx. %.1f GB".format(bytes / 1e9) else "approx. ${bytes / 1_000_000} MB"

    fun directory(root: File) = File(root, id)
    fun file(root: File, name: String) = File(directory(root), name)

    /** Installiert, wenn alle Dateien vollständig da sind (iOS: mindestens 95 % der erwarteten Bytes). */
    fun isInstalled(root: File): Boolean = files.all { f ->
        val file = file(root, f.name)
        file.exists() && file.length() >= f.bytes * 95 / 100
    }
}

private fun hf(repo: String, file: String) = "https://huggingface.co/$repo/resolve/main/$file"

/** Die Modelle der App. */
object ModelCatalog {
    /** iOS: Parakeet TDT v3 (0.6B) über FluidAudio — hier die int8-ONNX-Fassung für sherpa-onnx. */
    val parakeet = ModelPack(
        "parakeet-tdt-0.6b-v3", "Parakeet TDT v3",
        listOf(
            ModelFile(hf("csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", "encoder.int8.onnx"), "encoder.int8.onnx", "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247", 652_184_281),
            ModelFile(hf("csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", "decoder.int8.onnx"), "decoder.int8.onnx", "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e", 11_845_275),
            ModelFile(hf("csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", "joiner.int8.onnx"), "joiner.int8.onnx", "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3", 6_355_277),
            ModelFile(hf("csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", "tokens.txt"), "tokens.txt", null, 93_939),
        ),
    )

    /** iOS: pyannote-Diarisierung über FluidAudio — Segmentierung 3.0 und eine Sprecher-Einbettung. */
    val diarizer = ModelPack(
        "speakers", "Speaker Detection",
        listOf(
            ModelFile(hf("csukuangfj/sherpa-onnx-pyannote-segmentation-3-0", "model.onnx"), "segmentation.onnx", "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079", 6_000_000),
            ModelFile(hf("csukuangfj/speaker-embedding-models", "wespeaker_en_voxceleb_CAM++.onnx"), "embedding.onnx", "c46fad10b5f81e1aa4a60c162714208577093655076c5450f8c469e522ec54ef", 29_300_000),
        ),
    )

    /** iOS: `NLContextualEmbedding` (eingebaut). Hier ein mehrsprachiges Einbettungsmodell für llama.cpp. */
    val embedder = ModelPack(
        "qwen3-embedding-0.6b", "Meaning Search",
        listOf(ModelFile(hf("Qwen/Qwen3-Embedding-0.6B-GGUF", "Qwen3-Embedding-0.6B-Q8_0.gguf"), "model.gguf", "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439", 639_150_592)),
    )
}

/** iOS: `LocalModel` — die Zusammenfassungsmodelle auf dem Gerät. */
enum class LocalModel(val raw: String, val displayName: String, val pack: ModelPack, val thinks: Boolean) {
    /** Dasselbe Modell wie iOS (Qwen3-4B-Instruct-2507), als GGUF. */
    QWEN3(
        "qwen3", "Qwen3 4B",
        ModelPack("qwen3-4b-instruct-2507", "Qwen3 4B", listOf(ModelFile(hf("unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"), "model.gguf", "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597", 2_497_000_000))),
        thinks = false,
    ),
    /** Für Geräte mit weniger als 8 GB Arbeitsspeicher. */
    QWEN3_SMALL(
        "qwen3small", "Qwen3 1.7B",
        ModelPack("qwen3-1.7b", "Qwen3 1.7B", listOf(ModelFile(hf("Qwen/Qwen3-1.7B-GGUF", "Qwen3-1.7B-Q8_0.gguf"), "model.gguf", "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a", 1_834_426_016))),
        thinks = true,
    );

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: QWEN3

        /** Arbeitsspeicher des Geräts in GB (für die Empfehlung 4B oder 1.7B). */
        fun totalMemoryGB(context: Context): Double {
            val info = ActivityManager.MemoryInfo()
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
            return info.totalMem / 1e9
        }

        fun recommended(context: Context) = if (totalMemoryGB(context) >= 7.5) QWEN3 else QWEN3_SMALL
    }
}

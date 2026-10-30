package de.letzgo.porridge.store

import de.letzgo.porridge.audio.AacWriter
import de.letzgo.porridge.audio.AudioDecoder
import de.letzgo.porridge.audio.Resampler
import de.letzgo.porridge.logic.NoteMergeLogic
import de.letzgo.porridge.model.Note
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * iOS: `NoteMerger` (Services/NoteMerger.swift) — fügt mehrere aufgenommene Notizen zu einer: Transkripte zeitlich
 * geordnet, Sprecher abgeglichen, Aufnahmen aneinandergehängt (neu kodiert auf gemeinsame Rate und Kanalzahl).
 */
class NoteMerger(private val db: PorridgeDatabase = PorridgeDatabase.shared) {
    /** Fügt [others] in [base] ein; [base] behält seinen Titel, die anderen werden gelöscht. */
    suspend fun merge(others: List<Note>, base: Note) {
        val ordered = (listOf(base) + others).sortedBy { it.createdAt }
        val oldAudio = ordered.mapNotNull { it.audioFileName }
        var merged: String? = null
        var channels: Int? = null
        val (offsets, total) = if (ordered.all { it.hasLocalAudio }) {
            val joined = withContext(Dispatchers.IO) { concatenate(oldAudio) }
            merged = joined.fileName
            channels = joined.channels
            joined.offsets to joined.duration
        } else NoteMergeLogic.offsetsWithoutAudio(ordered)
        val result = NoteMergeLogic.merge(base, ordered, offsets, total, merged, channels)
        // Alte Aufnahmen erst löschen, wenn alles oben geklappt hat.
        oldAudio.forEach(AudioStore::delete)
        db.notes().upsert(result)
        val store = NoteStore(db)
        others.forEach { store.deletePermanently(it.copy(audioFileName = null)) }
    }

    private class Joined(val fileName: String, val offsets: List<Double>, val duration: Double, val channels: Int)

    private fun concatenate(files: List<String>): Joined {
        // Gemeinsames Format: die höchste Rate und Kanalzahl der Teile.
        var rate = 16_000
        var channels = 1
        for (name in files) AudioStore.audioInfo(name)?.let { channels = maxOf(channels, it.second) }
        for (name in files) rate = maxOf(rate, sampleRate(name))
        val name = AudioStore.newFileName()
        val writer = AacWriter(AudioStore.file(name), rate, channels)
        val offsets = mutableListOf<Double>()
        try {
            for (file in files) {
                offsets += writer.duration
                var resamplers: List<Resampler>? = null
                AudioDecoder.decode(AudioStore.file(file), { info -> resamplers = List(channels) { Resampler(info.sampleRate, rate) } }) { block, ch ->
                    val frames = block.size / ch
                    val perChannel = List(channels) { c -> resamplers!![c].process(FloatArray(frames) { f -> block[f * ch + minOf(c, ch - 1)] }) }
                    val n = perChannel.minOf { it.size }
                    val pcm = ShortArray(n * channels)
                    for (f in 0 until n) for (c in 0 until channels) pcm[f * channels + c] = (perChannel[c][f].coerceIn(-1f, 1f) * 32767).toInt().toShort()
                    writer.write(pcm, pcm.size)
                }
            }
        } catch (e: Throwable) {
            writer.close()
            AudioStore.delete(name)
            throw IllegalStateException("The recordings could not be combined.", e)
        }
        val duration = writer.duration
        writer.close()
        return Joined(name, offsets, duration, channels)
    }

    private fun sampleRate(name: String): Int = runCatching {
        val extractor = android.media.MediaExtractor()
        try {
            extractor.setDataSource(AudioStore.file(name).absolutePath)
            (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                .first { it.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                .getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
        } finally {
            extractor.release()
        }
    }.getOrDefault(16_000)
}

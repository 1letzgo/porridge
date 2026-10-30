package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * iOS: `VoiceProfile` — die Stimme einer Person, gelernt beim Benennen eines Sprechers. Gespeichert wird
 * nur der Stimmabdruck (Float32-Bytes, L2-normiert), nie Audio. Die Vektoren stammen auf Android aus einem
 * anderen Modell als auf iOS und sind nicht austauschbar (es gibt keinen Sync).
 */
@Serializable
@Entity(tableName = "voice_profiles")
data class VoiceProfile(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String = "",
    @Serializable(with = Base64ByteArraySerializer::class)
    val voiceData: ByteArray = ByteArray(0),
    val seconds: Double = 0.0,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val voice: FloatArray get() = VoiceMath.floats(voiceData)

    override fun equals(other: Any?) = other is VoiceProfile && other.id == id && other.updatedAt == updatedAt && voiceData.contentEquals(other.voiceData)
    override fun hashCode() = id.hashCode()
}

/** iOS: `VoiceMath.data(from:)` / `floats(from:)` — Float32 little-endian. */
object VoiceMath {
    fun data(voice: FloatArray): ByteArray =
        ByteBuffer.allocate(voice.size * 4).order(ByteOrder.LITTLE_ENDIAN).apply { asFloatBuffer().put(voice) }.array()

    fun floats(data: ByteArray): FloatArray {
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }
}

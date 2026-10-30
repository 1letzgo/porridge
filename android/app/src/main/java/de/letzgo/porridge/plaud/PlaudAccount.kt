package de.letzgo.porridge.plaud

import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.data.SecureStore
import kotlinx.serialization.Serializable

/**
 * iOS: `PlaudAccount` — was der Plaud-Import zwischen Nutzungen behält: Anmeldetoken, der eigene Schlüssel und die
 * Geräte-Signaturen. Im [SecureStore] (Konto `plaud.account`), anders als iOS nur auf diesem Gerät.
 */
@Serializable
data class PlaudAccount(
    val userToken: String? = null,
    /** Das `pld_urt`-Cookie: erneuert `userToken`, wenn es abgelaufen ist. */
    val refreshToken: String? = null,
    val apiHost: String = "https://api.plaud.ai",
    /** RSA-Schlüssel von Plaud (PKCS#8-PEM); der Recorder verschlüsselt alles damit. */
    val privatePEM: String? = null,
    val publicPEM: String? = null,
    /** Seriennummer → Base64-Signatur des Geräts. */
    val signatures: Map<String, String> = emptyMap(),
    val lastSerial: String? = null,
) {
    fun save() = SecureStore.set(PorridgeJson.encodeToString(serializer(), this), ACCOUNT)

    companion object {
        private const val ACCOUNT = "plaud.account"

        fun load(): PlaudAccount = SecureStore.get(ACCOUNT)?.let { runCatching { PorridgeJson.decodeFromString(serializer(), it) }.getOrNull() } ?: PlaudAccount()

        fun clear() = SecureStore.set(null, ACCOUNT)
    }
}

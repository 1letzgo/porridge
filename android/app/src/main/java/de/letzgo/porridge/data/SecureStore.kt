package de.letzgo.porridge.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * iOS: `Keychain` (Services/Keychain.swift). API-Schlüssel und das Plaud-Konto, verschlüsselt mit einem
 * Schlüssel aus dem Android Keystore. Anders als die iCloud-Schlüsselbund-Einträge auf iOS bleiben sie auf
 * diesem Gerät. Accounts wie iOS: `openrouter-api-key`, `api-key.<provider>`, `plaud.account`.
 */
object SecureStore {
    private lateinit var prefs: SharedPreferences

    private const val FILE = "porridge.secure"

    fun init(context: Context) {
        prefs = try {
            open(context)
        } catch (e: Exception) {
            // Die Datei passt nicht zum Schlüssel dieses Geräts (von einem anderen Gerät übernommen, Keystore zurückgesetzt).
            // Lesbar wird sie nie mehr, und ohne das stürzte die App bei jedem Start ab: neu anfangen, die Schlüssel
            // und Konten werden noch einmal eingegeben.
            Log.w("SecureStore", "unreadable, starting empty: $e")
            context.deleteSharedPreferences(FILE)
            runCatching { java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS) }
            open(context)
        }
    }

    private fun open(context: Context): SharedPreferences {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        return EncryptedSharedPreferences.create(
            context, FILE, key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun get(account: String): String? = prefs.getString(account, null)

    /** `null` oder leer löscht den Eintrag (wie `Keychain.set(nil, for:)`). */
    fun set(value: String?, account: String) {
        val trimmed = value?.trim()
        prefs.edit().apply { if (trimmed.isNullOrEmpty()) remove(account) else putString(account, trimmed) }.apply()
    }
}

package de.letzgo.porridge.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * iOS: `Keychain` (Services/Keychain.swift). API-Schlüssel und das Plaud-Konto, verschlüsselt mit einem
 * Schlüssel aus dem Android Keystore. Anders als die iCloud-Schlüsselbund-Einträge auf iOS bleiben sie auf
 * diesem Gerät. Accounts wie iOS: `openrouter-api-key`, `api-key.<provider>`, `plaud.account`.
 */
object SecureStore {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        prefs = EncryptedSharedPreferences.create(
            context, "porridge.secure", key,
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

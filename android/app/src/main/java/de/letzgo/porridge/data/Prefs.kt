package de.letzgo.porridge.data

import android.content.Context
import android.content.SharedPreferences

/**
 * iOS: `UserDefaults` + `AppSettings`. Die Schlüssel sind dieselben Strings wie auf iOS, damit Logik und
 * Doku vergleichbar bleiben (es gibt keinen Sync, nur gleiche Namen).
 */
object Keys {
    const val SPEECH_ENGINE = "speechEngine"
    const val ONBOARDING_DONE = "onboardingDone"
    const val LANGUAGE = "transcriptionLanguage"
    const val SPEAKER_DETECTION = "speakerDetection"
    const val VOICE_RECOGNITION = "voiceRecognition"
    const val BILLING = "summaryBilling"
    const val LOCAL_MODEL = "localModel"
    const val PROVIDER = "aiProvider"
    const val CUSTOM_BASE_URL = "aiCustomBaseURL"
    /** Eigener Name (weitere Schreibweisen mit Komma): seine Aufgaben stehen unter „Mine“ (iOS: `myName`). */
    const val MY_NAME = "myName"
    const val TRANSCRIPTION_BILLING = "transcriptionBilling"
    const val PLAUD_IMPORTED = "plaud.importedSessions"
    const val PLAUD_LAST_PERIPHERAL = "lastHandshakenPeripheralId"
    /** iOS (Mac): `AppUpdate.skippedKey`. */
    const val UPDATE_SKIPPED_TAG = "updateSkippedTag"
    const val UPDATE_LAST_CHECK = "updateLastCheck"

    fun aiModel(provider: String) = "aiModel.$provider"
    fun transcriptionModel(provider: String) = "transcriptionModel.$provider"
}

/** iOS: `AppSettings.languages`. */
val transcriptionLanguages = listOf(
    "auto" to "Automatic",
    "de" to "German",
    "en" to "English",
    "fr" to "French",
    "es" to "Spanish",
    "it" to "Italian",
    "nl" to "Dutch",
    "pt" to "Portuguese",
    "pl" to "Polish",
)

/** iOS: `SpeechEngine` — auf Android nur Parakeet (Apples Modell gibt es hier nicht); Cloud läuft über `transcriptionBilling`. */
enum class SpeechEngine(val raw: String, val label: String) {
    PARAKEET("parakeet", "Parakeet v3");
}

/** iOS: `SummaryBilling`. */
enum class SummaryBilling(val raw: String, val label: String) {
    LOCAL("local", "On-Device"),
    BYOK("byok", "Cloud");

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: LOCAL
    }
}

/** iOS: `UserDefaults.standard` mit den Vorgaben aus `AppSettings.registerDefaults()`. */
object Prefs {
    private lateinit var prefs: SharedPreferences

    private val defaults: Map<String, Any> = mapOf(
        Keys.LANGUAGE to "auto",
        Keys.SPEECH_ENGINE to SpeechEngine.PARAKEET.raw,
        Keys.ONBOARDING_DONE to false,
        Keys.SPEAKER_DETECTION to true,
        Keys.BILLING to SummaryBilling.LOCAL.raw,
        Keys.LOCAL_MODEL to "qwen3",
        Keys.VOICE_RECOGNITION to true,
        Keys.PROVIDER to "openRouter",
    )

    fun init(context: Context) {
        prefs = context.getSharedPreferences("porridge", Context.MODE_PRIVATE)
    }

    /** Für Unit-Tests ohne Android-Kontext. */
    internal fun initForTests(store: SharedPreferences) {
        prefs = store
    }

    fun string(key: String): String? = if (prefs.contains(key)) prefs.getString(key, null) else defaults[key] as? String
    fun bool(key: String): Boolean = if (prefs.contains(key)) prefs.getBoolean(key, false) else (defaults[key] as? Boolean ?: false)
    fun long(key: String): Long = prefs.getLong(key, 0L)
    fun int(key: String): Int = prefs.getInt(key, 0)
    fun stringSet(key: String): Set<String> = prefs.getStringSet(key, emptySet()) ?: emptySet()

    fun set(key: String, value: String?) = prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    fun set(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
    fun set(key: String, value: Long) = prefs.edit().putLong(key, value).apply()
    fun set(key: String, value: Int) = prefs.edit().putInt(key, value).apply()
    fun set(key: String, value: Set<String>) = prefs.edit().putStringSet(key, value).apply()
    fun remove(key: String) = prefs.edit().remove(key).apply()

    val language: String get() = string(Keys.LANGUAGE) ?: "auto"
    val speakerDetectionEnabled: Boolean get() = bool(Keys.SPEAKER_DETECTION)
    val voiceRecognitionEnabled: Boolean get() = bool(Keys.VOICE_RECOGNITION)
    val billing: SummaryBilling get() = SummaryBilling.of(string(Keys.BILLING))
}

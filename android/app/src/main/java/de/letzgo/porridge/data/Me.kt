package de.letzgo.porridge.data

import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.VoiceProfile
import de.letzgo.porridge.sync.NextcloudSync

/** iOS: `AppSettings.myNames` / `isMe` / `setMyVoice` — wer der Nutzer ist: sein Name und die Stimme, die er in den Einstellungen als seine markiert hat. */
object Me {
    /** `VoiceProfile.id` der eigenen Stimme. */
    val voiceID: String? get() = Prefs.string(Keys.MY_VOICE)

    /** Die Namen des Nutzers, klein geschrieben, samt dem Namen der eigenen Stimme. */
    val names: List<String>
        get() = parseNames(Prefs.string(Keys.MY_NAME)) +
            listOfNotNull(Prefs.string(Keys.MY_VOICE_NAME)?.trim()?.lowercase()?.takeIf { it.isNotEmpty() })

    /** Der Name für die Zusammenfassungen: der erste aus den Einstellungen, sonst der der eigenen Stimme. */
    val name: String?
        get() = Prefs.string(Keys.MY_NAME).orEmpty().split(",").firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
            ?: Prefs.string(Keys.MY_VOICE_NAME)?.takeIf { it.isNotBlank() }

    fun isMe(speaker: Speaker): Boolean =
        (speaker.profileID != null && speaker.profileID == voiceID) || isMe(speaker.name, names)

    /** iOS: `AppSettings.myNames` — die Namen, klein geschrieben; leer, wenn keiner gesetzt ist. */
    fun parseNames(raw: String?): List<String> = raw.orEmpty().split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }

    /** iOS: `AppSettings.isMe` — ob ein Sprecher-Name der Nutzer ist: ganzer Name oder Vorname einer Seite. */
    fun isMe(name: String, names: List<String>): Boolean {
        val value = name.trim().lowercase()
        if (value.isEmpty()) return false
        return names.any { mine -> value == mine || value.split(" ").first() == mine || mine.split(" ").first() == value }
    }

    /** Markiert eine Stimme als die eigene (null: keine). */
    fun setVoice(profile: VoiceProfile?) {
        Prefs.set(Keys.MY_VOICE, profile?.id)
        Prefs.set(Keys.MY_VOICE_NAME, profile?.name)
        // Der Name folgt dem Nutzer auf seine anderen Geräte.
        NextcloudSync.syncSoon()
    }
}

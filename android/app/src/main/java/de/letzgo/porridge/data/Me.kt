package de.letzgo.porridge.data

import de.letzgo.porridge.logic.ActionItemsLogic
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.VoiceProfile

/** iOS: `AppSettings.myNames` / `isMe` / `setMyVoice` — wer der Nutzer ist: sein Name und die Stimme, die er in den Einstellungen als seine markiert hat. */
object Me {
    /** `VoiceProfile.id` der eigenen Stimme. */
    val voiceID: String? get() = Prefs.string(Keys.MY_VOICE)

    /** Die Namen des Nutzers, klein geschrieben, samt dem Namen der eigenen Stimme. */
    val names: List<String>
        get() = ActionItemsLogic.myNames(Prefs.string(Keys.MY_NAME)) +
            listOfNotNull(Prefs.string(Keys.MY_VOICE_NAME)?.trim()?.lowercase()?.takeIf { it.isNotEmpty() })

    /** Der Name für die Zusammenfassungen: der erste aus den Einstellungen, sonst der der eigenen Stimme. */
    val name: String?
        get() = Prefs.string(Keys.MY_NAME).orEmpty().split(",").firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
            ?: Prefs.string(Keys.MY_VOICE_NAME)?.takeIf { it.isNotBlank() }

    fun isMe(speaker: Speaker): Boolean =
        (speaker.profileID != null && speaker.profileID == voiceID) || ActionItemsLogic.isMe(speaker.name, names)

    /** Markiert eine Stimme als die eigene (null: keine). */
    fun setVoice(profile: VoiceProfile?) {
        Prefs.set(Keys.MY_VOICE, profile?.id)
        Prefs.set(Keys.MY_VOICE_NAME, profile?.name)
    }
}

package de.letzgo.porridge.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import de.letzgo.porridge.data.Keys
import de.letzgo.porridge.data.LinkImport
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.audio.RecordingSession
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.ui.components.ListPage
import de.letzgo.porridge.ui.notes.NoteDetailScreen
import de.letzgo.porridge.ui.notes.ListState
import de.letzgo.porridge.ui.notes.NotesScreen
import de.letzgo.porridge.ui.onboarding.OnboardingScreen
import de.letzgo.porridge.ui.plaud.PlaudImportScreen
import de.letzgo.porridge.ui.recording.RecordMeetingSheet
import de.letzgo.porridge.ui.recording.RecordingScreen
import de.letzgo.porridge.ui.settings.SettingsScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Bildschirme über der Liste (iOS: `NavigationSplitView` + Sheets). */
sealed interface Screen {
    data class Detail(val id: String, val draft: Note?) : Screen
    data class Recording(val title: String?, val continues: String? = null) : Screen
    data object Settings : Screen
    data class Plaud(val projectID: String?) : Screen
}

/** Ein geteilter Link, der noch geöffnet werden will (aus `MainActivity`, `ACTION_SEND`). */
object SharedLinks {
    val pending = MutableStateFlow<String?>(null)
}

/** iOS: `RootView` + `NotesView`-Navigation. */
@Composable
fun AppRoot() {
    var onboarded by remember { mutableStateOf(Prefs.bool(Keys.ONBOARDING_DONE)) }
    if (!onboarded) {
        OnboardingScreen { onboarded = true }
        return
    }
    val stack = remember { mutableStateListOf<Screen>() }
    /** Seite, Suche und Scroll-Position; bleiben, während eine Notiz daraus offen ist. */
    val list = remember { ListState() }
    var showCalendar by remember { mutableStateOf(false) }
    val coroutines = rememberCoroutineScope()
    fun push(screen: Screen) = stack.add(screen)
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    /** Öffnet eine Notiz; die Liste dahinter bleibt, wo sie ist. */
    fun open(id: String) {
        stack.removeAll { it is Screen.Detail }
        push(Screen.Detail(id, null))
    }

    // Das System hat die Activity neu aufgebaut, das Mikrofon läuft im Dienst weiter: die Aufnahme wieder zeigen.
    LaunchedEffect(Unit) { if (RecordingSession.isRecording && stack.isEmpty()) push(Screen.Recording(null)) }

    AppUpdateCheck()
    val pending by SharedLinks.pending.collectAsState()
    LaunchedEffect(pending) {
        val address = pending ?: return@LaunchedEffect
        SharedLinks.pending.value = null
        open(LinkImport.add(address).id)
    }

    // Seiten wechseln wie ein Projekt: sofort, ohne Blende.
    AnimatedContent(stack.lastOrNull(), transitionSpec = { EnterTransition.None togetherWith ExitTransition.None }, label = "screen") { top ->
        when (top) {
            null -> NotesScreen(
                list = list,
                onOpen = ::open,
                onNewNote = { pid -> val draft = Note(projectIDs = listOfNotNull(pid)); push(Screen.Detail(draft.id, draft)) },
                onRecord = { showCalendar = true },
                onSettings = { push(Screen.Settings) },
                onPlaud = { pid -> push(Screen.Plaud(pid)) },
            )
            is Screen.Detail -> NoteDetailScreen(top.id, top.draft, onContinueRecording = { note -> push(Screen.Recording(note.title, note.id)) }) { pop() }
            is Screen.Settings -> SettingsScreen(onBack = { pop() })
            is Screen.Plaud -> PlaudImportScreen(top.projectID, onBack = { pop() }) { id -> stack.clear(); open(id) }
            is Screen.Recording -> RecordingScreen(top.title, top.continues, onFinish = { result, names, liveText ->
                coroutines.launch {
                    // Aus einem offenen Projekt aufgenommen: das Meeting gehört dazu, die Ansicht bleibt.
                    val inProject = (list.page as? ListPage.Project)?.id
                    val note = withContext(NonCancellable) { RecordingSession.saveMeeting(result, names, liveText, top.title, inProject) }
                    pop()
                    open(note.id)
                }
            }, onCancel = { pop() })
        }
    }
    if (showCalendar) RecordMeetingSheet(onDismiss = { showCalendar = false }) { title ->
        showCalendar = false
        push(Screen.Recording(title))
    }
}

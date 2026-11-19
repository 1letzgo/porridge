package de.letzgo.porridge.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.ui.components.pageTransition
import androidx.compose.animation.AnimatedContent
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

/** Etwas Geteiltes, das noch gespeichert und geöffnet werden will (aus `MainActivity`, `ACTION_SEND`). */
object SharedLinks {
    val pending = MutableStateFlow<de.letzgo.porridge.data.ShareImport.Shared?>(null)
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
    val context = androidx.compose.ui.platform.LocalContext.current.applicationContext
    /** Richtung des nächsten Seitenwechsels. */
    var forward by remember { mutableStateOf(true) }
    fun push(screen: Screen) { forward = true; stack.add(screen) }
    fun pop() { forward = false; if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    /** Öffnet eine Notiz; die Liste dahinter bleibt, wo sie ist. */
    fun open(id: String) {
        stack.removeAll { it is Screen.Detail }
        push(Screen.Detail(id, null))
    }

    // Das System hat die Activity neu aufgebaut, das Mikrofon läuft im Dienst weiter: die Aufnahme wieder zeigen.
    LaunchedEffect(Unit) { if (RecordingSession.isRecording && stack.isEmpty()) push(Screen.Recording(null)) }

    AppUpdateCheck()
    val pending by SharedLinks.pending.collectAsState()
    var justShared by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(pending) {
        val shared = pending ?: return@LaunchedEffect
        SharedLinks.pending.value = null
        // In einem offenen Bucket Geteiltes gehört dazu.
        de.letzgo.porridge.data.ShareImport.save(context, shared, (list.page as? ListPage.Project)?.id)?.let {
            open(it.id)
            justShared = it.id
        }
    }
    // iOS: die Karte der Share-Extension — „Saved to Porridge“ mit Rückgängig, ein paar Sekunden lang.
    LaunchedEffect(justShared) {
        if (justShared != null) {
            kotlinx.coroutines.delay(5000)
            justShared = null
        }
    }

    AnimatedContent(stack.lastOrNull(), transitionSpec = { pageTransition(forward) }, label = "screen") { top ->
        when (top) {
            null -> NotesScreen(
                list = list,
                onOpen = ::open,
                onNewNote = { pid, todo ->
                    val draft = Note(
                        projectIDs = listOfNotNull(pid), sourceRaw = de.letzgo.porridge.model.NoteSource.NOTE.raw,
                        todoStateRaw = if (todo) de.letzgo.porridge.model.TodoState.OPEN.raw else null,
                    )
                    push(Screen.Detail(draft.id, draft))
                },
                onRecord = { showCalendar = true },
                onSettings = { push(Screen.Settings) },
                onPlaud = { pid -> push(Screen.Plaud(pid)) },
            )
            is Screen.Detail -> NoteDetailScreen(top.id, top.draft, onContinueRecording = { note -> push(Screen.Recording(note.title, note.id)) }, onOpenNote = { id -> push(Screen.Detail(id, null)) }) { pop() }
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
    justShared?.let { id ->
        androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.BottomCenter) {
            androidx.compose.material3.Snackbar(
                modifier = androidx.compose.ui.Modifier.navigationBarsPadding().padding(16.dp),
                action = {
                    androidx.compose.material3.TextButton(onClick = {
                        justShared = null
                        // Rückgängig: Die eben gesicherte Notiz geht samt ihren Dateien, und ihr Bildschirm schließt sich.
                        stack.removeAll { it is Screen.Detail && it.id == id }
                        coroutines.launch { de.letzgo.porridge.store.PorridgeDatabase.shared.notes().get(id)?.let { de.letzgo.porridge.store.NoteStore().deletePermanently(it) } }
                    }) { androidx.compose.material3.Text("Undo") }
                },
            ) { androidx.compose.material3.Text("Saved to Porridge") }
        }
    }
    if (showCalendar) RecordMeetingSheet(onDismiss = { showCalendar = false }) { title ->
        showCalendar = false
        push(Screen.Recording(title))
    }
}

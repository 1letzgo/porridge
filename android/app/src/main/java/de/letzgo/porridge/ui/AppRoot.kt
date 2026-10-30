package de.letzgo.porridge.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import de.letzgo.porridge.logic.SpeakerAssigner
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteScope
import de.letzgo.porridge.model.ProcessingStatus
import de.letzgo.porridge.model.Speaker
import de.letzgo.porridge.model.SpeakerMode
import de.letzgo.porridge.model.TranscriptSegment
import de.letzgo.porridge.processing.ProcessingService
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.components.ListMode
import de.letzgo.porridge.ui.tasks.TaskDetailScreen
import de.letzgo.porridge.ui.notes.NoteDetailScreen
import de.letzgo.porridge.ui.tasks.TaskDetailScreen
import de.letzgo.porridge.ui.notes.NotesScreen
import de.letzgo.porridge.ui.onboarding.OnboardingScreen
import de.letzgo.porridge.ui.plaud.PlaudImportScreen
import de.letzgo.porridge.ui.recording.RecordMeetingSheet
import de.letzgo.porridge.ui.recording.RecordingScreen
import de.letzgo.porridge.ui.settings.SettingsScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** Bildschirme über der Liste (iOS: `NavigationSplitView` + Sheets). */
sealed interface Screen {
    data class Detail(val id: String, val draft: Note?) : Screen
    data class Recording(val title: String?) : Screen
    data object Settings : Screen
    data object Plaud : Screen
    data class Task(val id: String) : Screen
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
    var scope by remember { mutableStateOf<NoteScope>(NoteScope.All) }
    // The app opens on the tasks; the notes are where they come from.
    var mode by remember { mutableStateOf(ListMode.TASKS) }
    var showCalendar by remember { mutableStateOf(false) }
    val coroutines = rememberCoroutineScope()
    fun push(screen: Screen) = stack.add(screen)
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    /** Öffnet eine Notiz; [into]: die Liste, in der sie danach steht (ein neues Meeting unter Meetings). */
    fun open(id: String, into: ListMode? = null) {
        if (into != null) mode = into
        stack.removeAll { it is Screen.Detail }
        push(Screen.Detail(id, null))
    }

    AppUpdateCheck()
    val pending by SharedLinks.pending.collectAsState()
    LaunchedEffect(pending) {
        val address = pending ?: return@LaunchedEffect
        SharedLinks.pending.value = null
        open(LinkImport.add(address, (scope as? NoteScope.Folder)?.id).id, ListMode.LINKS)
    }

    AnimatedContent(stack.lastOrNull(), transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "screen") { top ->
        when (top) {
            null -> NotesScreen(
                scope = scope, onScope = { scope = it }, mode = mode, onMode = { mode = it },
                onOpen = ::open,
                onNewNote = { folderID -> val draft = Note(folderID = folderID); push(Screen.Detail(draft.id, draft)) },
                onRecord = { showCalendar = true },
                onSettings = { push(Screen.Settings) },
                onEditTask = { push(Screen.Task(it)) },
            )
            is Screen.Task -> TaskDetailScreen(top.id, onOpenNote = { id -> pop(); open(id) }) { pop() }
            is Screen.Detail -> NoteDetailScreen(top.id, top.draft) { pop() }
            is Screen.Settings -> SettingsScreen(onBack = { pop() }, onPlaud = { push(Screen.Plaud) })
            is Screen.Plaud -> PlaudImportScreen(onBack = { pop() }) { id -> stack.clear(); open(id, ListMode.MEETINGS) }
            is Screen.Recording -> RecordingScreen(top.title, onFinish = { result, names, liveText ->
                coroutines.launch {
                    // Ein aufgenommenes Meeting wird eine Notiz, die mit Sprechern transkribiert wird.
                    var note = Note(
                        folderID = (scope as? NoteScope.Folder)?.id,
                        title = top.title ?: Note.defaultMeetingTitle(System.currentTimeMillis()), titleIsCustom = top.title != null,
                        statusRaw = ProcessingStatus.RECORDED.raw, audioFileName = result.fileName, duration = result.duration,
                        channelCount = result.channelCount, inputName = result.inputName,
                    )
                    if (result.isSplitStereo) {
                        note = note.copy(speakerModeRaw = SpeakerMode.CHANNELS.raw).withSpeakers(
                            listOf(Speaker(SpeakerAssigner.LEFT_CHANNEL_ID, names[0], 0), Speaker(SpeakerAssigner.RIGHT_CHANNEL_ID, names[1], 1)),
                        )
                    }
                    // Bis das Transkript mit Sprechern fertig ist, steht der Live-Text da.
                    if (liveText.isNotEmpty()) note = note.withSegments(listOf(TranscriptSegment(start = 0.0, end = result.duration, text = liveText)))
                    PorridgeDatabase.shared.notes().upsert(note)
                    ProcessingService.enqueue(ProcessingService.Job.Transcript(note.id))
                    pop()
                    open(note.id, ListMode.MEETINGS)
                }
            }, onCancel = { pop() })
        }
    }
    if (showCalendar) RecordMeetingSheet(onDismiss = { showCalendar = false }) { title ->
        showCalendar = false
        push(Screen.Recording(title))
    }
}

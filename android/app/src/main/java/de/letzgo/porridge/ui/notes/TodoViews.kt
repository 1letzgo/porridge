package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material.icons.outlined.EventBusy
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.WbTwilight
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.logic.Todos
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.ui.Brand

/**
 * iOS: `TodoCheckbox` (Views/Notes/TodoViews.swift) — die Box eines To-dos: in der Listenzeile am Ende (das Symbol der
 * Art steht vorn wie bei jeder Notiz), auf seiner Seite vor dem Titel. Offen ein grüner Rand mit hellem Grün, erledigt
 * voll grün mit navy Haken.
 */
@Composable
fun TodoCheckbox(isDone: Boolean, size: Dp = 26.dp, isPinned: Boolean = false, enabled: Boolean = true, onToggle: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    // Mindestens 48 dp zum Tippen, wie klein die Box auch gezeichnet ist.
    Box(
        Modifier.size(maxOf(size, 48.dp)).clickable(enabled = enabled, role = Role.Checkbox, indication = null, interactionSource = null) {
            if (!isDone) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            onToggle()
        }.semantics { contentDescription = "To-do"; stateDescription = if (isDone) "Done" else "Not Done" },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(size / 4))
                .background(if (isDone) Brand.task else Brand.task.copy(alpha = 0.10f))
                .border(BorderStroke(1.5.dp, Brand.task.copy(alpha = if (isDone) 1f else 0.75f)), RoundedCornerShape(size / 4)),
            contentAlignment = Alignment.Center,
        ) {
            // Symbole auf voller grüner Fläche sind navy.
            if (isDone) Icon(Icons.Filled.Check, null, tint = Brand.onFill, modifier = Modifier.size(size * 0.55f))
        }
        if (isPinned) Box(
            Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp).size(18.dp).clip(CircleShape).background(Brand.navy),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.PushPin, "Pinned", tint = Brand.onFill(Brand.navy), modifier = Modifier.size(11.dp))
        }
    }
}

/** iOS: `TodoProgressLabel` — „2/5“ mit Checklisten-Symbol; grün, sobald alle abgehakt sind. Nichts ohne Unteraufgaben. */
@Composable
fun TodoProgressLabel(progress: Todos.Progress) {
    if (progress.total == 0) return
    val color = if (progress.isComplete) Brand.taskText else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = "${progress.done} of ${progress.total} subtasks done" },
    ) {
        // Kreise wie die Unteraufgaben im Text; `checklist` ist das Symbol der Art.
        Icon(Icons.Outlined.CheckCircle, null, tint = color, modifier = Modifier.size(13.dp))
        Text(progress.label, style = MaterialTheme.typography.labelSmall, color = color, maxLines = 1)
    }
}

/** iOS: `TodoSourcePill` — der Weg von einem To-do zurück zur Notiz, aus deren Zusammenfassung es stammt. */
@Composable
fun TodoSourcePill(source: Note, onOpen: (String) -> Unit) {
    Surface(
        shape = RoundedCornerShape(50), color = Brand.navy.copy(alpha = 0.08f),
        modifier = Modifier.clip(RoundedCornerShape(50)).clickable { onOpen(source.id) }.semantics { contentDescription = "From ${source.displayTitle}" },
    ) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 5.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(kindIcon(source), null, tint = Brand.navy, modifier = Modifier.size(16.dp))
            Text(source.displayTitle, style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold), color = Brand.navy, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Filled.ChevronRight, null, tint = Brand.navy, modifier = Modifier.size(14.dp))
        }
    }
}

// Art einer Notiz (iOS: `Note.kindSymbol`, `kindName`)

/** Das Symbol der Art: To-do `checklist`, Meeting, Notiz (mit Datei eine Büroklammer), Link, Bild, PDF, Datei. */
fun kindIcon(note: Note): ImageVector = when {
    note.isTodo -> Icons.Filled.Checklist
    note.isLink -> Icons.Filled.Link
    note.isImage -> Icons.Filled.Image
    note.isFile -> if (note.attachments.firstOrNull()?.kind == de.letzgo.porridge.model.Attachment.Kind.PDF) Icons.Filled.PictureAsPdf else Icons.Filled.Description
    note.isRecording -> Icons.Outlined.GraphicEq
    note.attachmentsData != null -> Icons.Filled.AttachFile
    else -> Icons.AutoMirrored.Filled.Notes
}

fun kindName(note: Note): String = when {
    note.isTodo -> "To-do"
    note.isLink -> "Link"
    note.isImage -> "Image"
    note.isFile -> "File"
    note.isRecording -> "Meeting"
    else -> "Note"
}

// Fälliger Tag (iOS: `TodoDueLabel`, `DueDateMenuItems`, `DueDateChip`, `DueDatePickerSheet`)

/** Die Farbe eines fälligen Tages: rot, wenn ein offenes To-do spät dran ist, grün für heute, sonst ruhig. Ein erledigtes nie. */
@Composable
fun dueTint(note: Note): Color {
    val due = note.todoDue
    if (due == null || note.isDone) return MaterialTheme.colorScheme.onSurfaceVariant
    return when (Todos.dueStatus(due)) {
        Todos.DueStatus.OVERDUE -> Brand.dangerText
        Todos.DueStatus.TODAY -> Brand.taskText
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
}

/** Der fällige Tag in einer Listenzeile: Kalendersymbol und "Today", "Fri", "12 Dec". */
@Composable
fun TodoDueLabel(note: Note) {
    val due = note.todoDue ?: return
    val label = Todos.dueLabel(due)
    val strong = note.isOverdue || (Todos.dueStatus(due) == Todos.DueStatus.TODAY && !note.isDone)
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = if (note.isOverdue) "Overdue, due $label" else "Due $label" },
    ) {
        Icon(if (note.isOverdue) Icons.Outlined.EventBusy else Icons.Outlined.CalendarToday, null, tint = dueTint(note), modifier = Modifier.size(13.dp))
        Text(label, style = MaterialTheme.typography.labelSmall.copy(fontWeight = if (strong) FontWeight.SemiBold else null), color = dueTint(note), maxLines = 1)
    }
}

/** Die Wahl eines fälligen Tages als Menü: Today, Tomorrow, Next Week, Pick Date… und Clear Due Date. */
@Composable
fun DueDateMenu(note: Note, expanded: Boolean, onDismiss: () -> Unit, onSet: (String?) -> Unit) {
    var picking by remember { mutableStateOf(false) }
    DropdownMenu(expanded, onDismissRequest = onDismiss) {
        for (choice in Todos.DueChoice.entries) {
            val icon = when (choice) {
                Todos.DueChoice.TODAY -> Icons.Outlined.StarOutline
                Todos.DueChoice.TOMORROW -> Icons.Outlined.WbTwilight
                Todos.DueChoice.NEXT_WEEK -> Icons.Outlined.DateRange
            }
            DropdownMenuItem(text = { Text(choice.title) }, leadingIcon = { Icon(icon, null) }, onClick = { onDismiss(); onSet(Todos.dueKey(choice)) })
        }
        DropdownMenuItem(text = { Text("Pick Date…") }, leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null) }, onClick = { onDismiss(); picking = true })
        if (note.todoDue != null) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Clear Due Date", color = Brand.dangerText) }, leadingIcon = { Icon(Icons.Outlined.EventBusy, null, tint = Brand.dangerText) },
                onClick = { onDismiss(); onSet(null) },
            )
        }
    }
    if (picking) DueDatePicker(note, onDismiss = { picking = false }) { key -> picking = false; onSet(key) }
}

/** Der Kalender des Systems, um einen fälligen Tag zu wählen. Der Material-Wähler rechnet in UTC-Mitternacht. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DueDatePicker(note: Note, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val initial = (note.todoDue?.let { Todos.dueDay(it) } ?: LocalDate.now()).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val state = rememberDatePickerState(initialSelectedDateMillis = initial)
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { onPick(Todos.dueKey(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate())) } ?: onDismiss()
            }) { Text("Done") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    ) {
        DatePicker(state, title = { Text("Due Date", modifier = Modifier.padding(start = 24.dp, top = 16.dp)) }, colors = DatePickerDefaults.colors(selectedDayContainerColor = Brand.task, todayDateBorderColor = Brand.task, todayContentColor = Brand.taskText))
    }
}

/** Der fällige Tag auf der Seite eines To-dos, als erster Chip vor Buckets und Tags: ein Menü mit der Wahl. */
@Composable
fun DueDateChip(note: Note, onSet: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val due = note.todoDue
    val color = if (due == null) Brand.navy else if (note.isOverdue) Brand.dangerText else Brand.taskText
    val fill = if (due == null) MaterialTheme.colorScheme.surfaceVariant else if (note.isOverdue) Brand.danger.copy(alpha = 0.15f) else Brand.task.copy(alpha = 0.18f)
    Box {
        Surface(
            onClick = { open = true }, shape = RoundedCornerShape(50), color = fill,
            modifier = Modifier.semantics { contentDescription = due?.let { "Due ${Todos.dueLabel(it)}" } ?: "Add Due Date" },
        ) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(if (due == null) Icons.Filled.Add else if (note.isOverdue) Icons.Outlined.EventBusy else Icons.Outlined.CalendarToday, null, tint = color, modifier = Modifier.size(16.dp))
                Text(due?.let { Todos.dueLabel(it) } ?: "Due Date", style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold), color = color)
            }
        }
        DueDateMenu(note, open, onDismiss = { open = false }, onSet = onSet)
    }
}

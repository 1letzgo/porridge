package de.letzgo.porridge.ui.notes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChecklistRtl
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
 * iOS: `TodoCheckbox` (Views/Notes/TodoViews.swift) — die Box eines To-dos: in der Listenzeile anstelle des Symbols der
 * Art (so groß wie es), auf seiner Seite vor dem Titel. Grüne Quadrate sind Aufgaben; Kreise die Unteraufgaben im Text.
 */
@Composable
fun TodoCheckbox(isDone: Boolean, size: Dp = 44.dp, isPinned: Boolean = false, enabled: Boolean = true, onToggle: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    Box {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(size / 4))
                .background(if (isDone) Brand.task else Brand.task.copy(alpha = 0.10f))
                .border(BorderStroke(1.5.dp, Brand.task.copy(alpha = if (isDone) 1f else 0.75f)), RoundedCornerShape(size / 4))
                .clickable(enabled = enabled, role = Role.Checkbox) {
                    if (!isDone) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onToggle()
                }
                .semantics { contentDescription = "To-do"; stateDescription = if (isDone) "Done" else "Not Done" },
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
        Icon(Icons.Filled.ChecklistRtl, null, tint = color, modifier = Modifier.size(13.dp))
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
            Icon(if (source.isRecording) Icons.Outlined.GraphicEq else Icons.AutoMirrored.Filled.Notes, null, tint = Brand.navy, modifier = Modifier.size(16.dp))
            Text(source.displayTitle, style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold), color = Brand.navy, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Filled.ChevronRight, null, tint = Brand.navy, modifier = Modifier.size(14.dp))
        }
    }
}

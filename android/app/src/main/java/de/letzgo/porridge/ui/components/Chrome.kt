package de.letzgo.porridge.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.ui.Brand

/** iOS: `ChromeBar` — eigene Leiste wie in Things: farbiges Listen-Icon und großer Titel links, schlichte Icons rechts. */
@Composable
fun ChromeBar(title: String, icon: ImageVector?, tint: Color = Brand.sky, actions: @Composable RowScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 20.dp, end = 8.dp, top = 8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            actions()
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 2.dp, bottom = 8.dp)) {
            if (icon != null) {
                Box(Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(tint), contentAlignment = Alignment.Center) {
                    Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(10.dp))
            }
            Text(title, style = MaterialTheme.typography.headlineLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** iOS: `ListTabs` — Timeline, Tasks, Chat, Search. */
/** MEETINGS: die Aufnahmen; TIMELINE: die geschriebenen Notizen. [SEARCH] hat keinen Tab: sie öffnet sich über den Knopf in der Leiste. */
enum class ListMode(val title: String, val isTab: Boolean = true) {
    TASKS("Tasks"), MEETINGS("Meetings"), TIMELINE("Notes"), LINKS("Links"), CHAT("Chat"), SEARCH("Search", isTab = false);

    val color: Color get() = when (this) { TASKS -> Brand.task; LINKS -> LinkOrange; else -> Brand.sky }

    /** Notizen und Meetings folgen dem gewählten Ordner, Tag oder Papierkorb. */
    val showsScope: Boolean get() = this == TIMELINE || this == MEETINGS
}

@Composable
fun ListTabs(mode: ListMode, onChange: (ListMode) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (m in ListMode.entries.filter { it.isTab }) {
            FilterChip(
                selected = m == mode, onClick = { onChange(m) }, label = { Text(m.title) },
                // Jeder Tab in seiner Farbe, wie sein Titel-Quadrat (iOS: `TabSwitcher.tint`).
                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = m.color.copy(alpha = 0.16f), selectedLabelColor = Brand.navy),
                border = null,
            )
        }
    }
}

/** iOS: Abschnittstitel wie in Things — klein, fett, in der Akzentfarbe, über einer Haarlinie. */
@Composable
fun SectionHeader(title: String, count: Int? = null, modifier: Modifier = Modifier, color: Color = Brand.sky, trailing: @Composable () -> Unit = {}) {
    Column(modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = color)
            if (count != null) Text("  $count", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            trailing()
        }
        Spacer(Modifier.height(6.dp))
        HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
    }
}

/** iOS: `EmptyStateView`. */
@Composable
fun EmptyState(title: String, message: String, icon: ImageVector, modifier: Modifier = Modifier, action: @Composable () -> Unit = {}) {
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, contentDescription = null, tint = Brand.sky, modifier = Modifier.size(44.dp))
        Text(title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), textAlign = TextAlign.Center)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        action()
    }
}

/** iOS: `ThingsRowIcon` — kleines Symbol vor einer Zeile. */
@Composable
fun RowIcon(icon: ImageVector, tint: Color) {
    Box(Modifier.size(26.dp).clip(RoundedCornerShape(7.dp)).background(tint.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
    }
}

/** iOS: `FloatingActionButton` — runder Sky-Knopf mit weichem Schatten. */
@Composable
fun SkyFab(icon: ImageVector, label: String, modifier: Modifier = Modifier, container: Color = Brand.sky, onClick: () -> Unit) {
    FloatingActionButton(onClick = onClick, shape = CircleShape, containerColor = container, contentColor = Color.White, modifier = modifier.size(60.dp)) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(28.dp))
    }
}

/** Speaker-Farben (iOS: `Color.speaker(_:)`). */
val speakerColors = listOf(Color(0xFF24B4E9), Color(0xFFF2994A), Color(0xFF6FCF97), Color(0xFFBB6BD9), Color(0xFFEB5757), Color(0xFFF2C94C), Color(0xFF2D9CDB), Color(0xFF9B51E0))
fun speakerColor(index: Int) = speakerColors[((index % speakerColors.size) + speakerColors.size) % speakerColors.size]

/** Farbe gespeicherter Links (iOS: `brandLink`). */
val LinkOrange = Color(0xFFF2994A)

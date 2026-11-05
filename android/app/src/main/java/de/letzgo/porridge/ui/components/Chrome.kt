package de.letzgo.porridge.ui.components

import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
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
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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

/** iOS: `ChromeBar` — eigene Leiste wie in Things: farbiges Listen-Icon und Titel links, schlichte Icons rechts, alles in einer Zeile. */
@Composable
fun ChromeBar(title: String, icon: ImageVector?, tint: Color = Brand.sky, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = if (onBack != null) 4.dp else 20.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = if (tint == Brand.sky) Brand.navy else Brand.readable(tint)) }
        if (icon != null) {
            Box(Modifier.size(34.dp).clip(RoundedCornerShape(9.dp)).background(tint), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = Brand.onFill(tint), modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(10.dp))
        }
        Text(
            title, style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).semantics { heading() },
        )
        Spacer(Modifier.width(8.dp))
        actions()
    }
}

/** iOS: `ListPage` — was die Liste zeigt: die lange Startseite oder eine Unterseite mit Zurück. Die Suche liegt als Karte darüber. */
sealed interface ListPage {
    data object Home : ListPage
    data class Project(val id: String) : ListPage
    data object Archive : ListPage
    data object Trash : ListPage
}

/** iOS: Abschnittstitel wie in Things — klein, fett, in der Akzentfarbe, über einer Haarlinie. */
@Composable
fun SectionHeader(title: String, count: Int? = null, modifier: Modifier = Modifier, color: Color = Brand.sky, trailing: @Composable () -> Unit = {}) {
    Column(modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = Brand.readable(color), modifier = Modifier.semantics { heading() })
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
        Icon(icon, contentDescription = null, tint = Brand.skyText, modifier = Modifier.size(44.dp))
        Text(title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), textAlign = TextAlign.Center)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        action()
    }
}

/** iOS: `ThingsRowIcon` — kleines Symbol vor einer Zeile. */
@Composable
fun RowIcon(icon: ImageVector, tint: Color) {
    Box(Modifier.size(26.dp).clip(RoundedCornerShape(7.dp)).background(tint.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = Brand.readable(tint), modifier = Modifier.size(16.dp))
    }
}

/** iOS: `FloatingActionButton` — runder Sky-Knopf mit weichem Schatten. */
@Composable
fun SkyFab(icon: ImageVector, label: String, modifier: Modifier = Modifier, container: Color = Brand.sky, content: Color = Brand.onFill(container), onClick: () -> Unit) {
    // Material tönt einen Knopf in der Flächenfarbe je nach Höhe in der Primärfarbe; weiß soll weiß bleiben.
    MaterialTheme(colorScheme = MaterialTheme.colorScheme.copy(surfaceTint = container)) {
        FloatingActionButton(onClick = onClick, shape = CircleShape, containerColor = container, contentColor = content, modifier = modifier.size(60.dp)) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(28.dp))
        }
    }
}

/** Speaker-Farben (iOS: `Color.speaker(_:)`). */
val speakerColors = listOf(Color(0xFF24B4E9), Color(0xFFF58C33), Color(0xFF5CB85C), Color(0xFF9E6BDB), Color(0xFFED618C), Color(0xFF33A8A8))
fun speakerColor(index: Int) = speakerColors[((index % speakerColors.size) + speakerColors.size) % speakerColors.size]

/** Farbe gespeicherter Links (iOS: `brandLink`). */
val LinkOrange = Brand.link

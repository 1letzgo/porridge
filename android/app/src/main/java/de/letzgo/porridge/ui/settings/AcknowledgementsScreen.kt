package de.letzgo.porridge.ui.settings

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.letzgo.porridge.data.PorridgeJson
import de.letzgo.porridge.ui.Brand
import kotlinx.serialization.Serializable

/**
 * Die Pakete und Modelle anderer, die die App nutzt (`assets/acknowledgements.json`, erzeugt von
 * scripts/acknowledgements.py): Name, Version, Lizenz und der volle Lizenztext. Gleiche Texte stehen einmal in `licenses`.
 */
@Serializable
data class Acknowledgements(val licenses: Map<String, String>, val sections: List<Section>) {
    @Serializable
    data class Section(val title: String, val entries: List<Entry>)

    @Serializable
    data class Entry(val name: String, val version: String, val license: String, val url: String, val text: String)

    companion object {
        fun load(context: Context): Acknowledgements = runCatching {
            context.assets.open("acknowledgements.json").bufferedReader().use { PorridgeJson.decodeFromString<Acknowledgements>(it.readText()) }
        }.getOrDefault(Acknowledgements(emptyMap(), emptyList()))
    }
}

/** iOS: `AcknowledgementsView` — Gruppen wie die Karten der Einstellungen, ein Tipp klappt den Lizenztext auf. */
@Composable
fun AcknowledgementsScreen(onBack: () -> Unit) {
    BackHandler { onBack() }
    val context = LocalContext.current
    val list = remember { Acknowledgements.load(context) }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Brand.navy) }
            Text("Acknowledgements", style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold))
        }
        LazyColumn(Modifier.fillMaxSize().navigationBarsPadding(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                Text(
                    "Porridge is built with these open source packages and models. Thank you to everyone who made them.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                )
            }
            list.sections.forEach { section ->
                item(key = "title:" + section.title) {
                    Text(
                        section.title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), color = Brand.navy,
                        modifier = Modifier.padding(start = 4.dp, top = 14.dp),
                    )
                }
                items(section.entries, key = { section.title + ":" + it.name }) { entry ->
                    EntryCard(entry, list.licenses[entry.text].orEmpty())
                }
            }
        }
    }
}

@Composable
private fun EntryCard(entry: Acknowledgements.Entry, text: String) {
    var open by rememberSaveable(entry.name) { mutableStateOf(false) }
    val uri = LocalUriHandler.current
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 1.dp) {
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(entry.name, fontWeight = FontWeight.SemiBold)
                    Text(
                        listOf(entry.version, entry.license).filter { it.isNotEmpty() }.joinToString(" · "),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Icon(
                    if (open) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    if (open) "Hide License" else "Show License", tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            AnimatedVisibility(open) {
                Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    HorizontalDivider()
                    Text(entry.url, style = MaterialTheme.typography.labelSmall, color = Brand.sky, maxLines = 1, modifier = Modifier.clickable { runCatching { uri.openUri(entry.url) } })
                    SelectionContainer {
                        Text(text, fontFamily = FontFamily.Monospace, fontSize = 10.sp, lineHeight = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

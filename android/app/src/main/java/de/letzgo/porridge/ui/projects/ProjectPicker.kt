package de.letzgo.porridge.ui.projects

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.data.Projects
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.store.PorridgeDatabase
import de.letzgo.porridge.ui.Brand
import de.letzgo.porridge.ui.notes.TextPrompt
import kotlinx.coroutines.launch
import java.text.Collator

/** Projekte nach Namen sortiert, wie überall in der App. */
fun List<NoteFolder>.sortedByName(): List<NoteFolder> {
    val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
    return sortedWith { a, b -> collator.compare(a.name, b.name) }
}

/**
 * Projekt-Pillen (violett) und „+ Project“ mit Auswahl aller Projekte und „New Project…“. Steht in einer `Row`;
 * [inherited]: Projekte, die von woanders kommen (die Notiz einer Aufgabe), blass und hier nicht abwählbar.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ProjectPills(assigned: List<String>, onToggle: (String) -> Unit, inherited: List<String> = emptyList()) {
    val projects by PorridgeDatabase.shared.folders().observeAll().collectAsState(initial = emptyList())
    val sorted = remember(projects) { projects.sortedByName() }
    val coroutines = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var creating by remember { mutableStateOf(false) }

    for (project in sorted) {
        val own = project.id in assigned
        val fromNote = project.id in inherited && !own
        if (!own && !fromNote) continue
        Surface(shape = RoundedCornerShape(50), color = Brand.project.copy(alpha = if (own) 0.18f else 0.08f)) {
            Row(Modifier.padding(start = 12.dp, end = if (own) 4.dp else 12.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Folder, null, tint = Brand.project.copy(alpha = if (own) 1f else 0.5f), modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text(project.name, style = MaterialTheme.typography.labelLarge, color = Brand.project.copy(alpha = if (own) 1f else 0.6f))
                if (own) Icon(Icons.Filled.Close, "Remove from Project", tint = Brand.project, modifier = Modifier.padding(start = 4.dp).size(16.dp).clip(CircleShape).combinedClickable(onClick = { onToggle(project.id) }))
            }
        }
    }
    Box {
        Surface(onClick = { menu = true }, shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceVariant) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, "Add to Project", tint = Brand.project, modifier = Modifier.size(16.dp))
                Text(" Project", style = MaterialTheme.typography.labelLarge, color = Brand.project)
            }
        }
        DropdownMenu(menu, onDismissRequest = { menu = false }) {
            for (project in sorted) {
                val fromNote = project.id in inherited && project.id !in assigned
                DropdownMenuItem(
                    text = { Text(project.name) }, enabled = !fromNote,
                    leadingIcon = {
                        if (project.id in assigned || fromNote) Icon(Icons.Filled.Check, null, tint = Brand.project.copy(alpha = if (fromNote) 0.5f else 1f))
                        else Spacer(Modifier.size(24.dp))
                    },
                    onClick = { menu = false; onToggle(project.id) },
                )
            }
            if (sorted.isNotEmpty()) HorizontalDivider()
            DropdownMenuItem(
                text = { Text("New Project…") }, leadingIcon = { Icon(Icons.Filled.Add, null, tint = Brand.project) },
                onClick = { menu = false; creating = true },
            )
        }
    }
    if (creating) TextPrompt("New Project", "", "Create", onDismiss = { creating = false }) { name ->
        creating = false
        coroutines.launch { onToggle(Projects.create(name).id) }
    }
}

/**
 * iOS: `ProjectMenu` — „Projects…“ beim langen Drücken: alle Projekte zum Abhaken. [inherited] (die Notiz einer
 * Aufgabe) erscheinen abgehakt und gesperrt.
 */
@Composable
fun ProjectChooser(assigned: List<String>, onToggle: (String) -> Unit, onDismiss: () -> Unit, inherited: List<String> = emptyList()) {
    val projects by PorridgeDatabase.shared.folders().observeAll().collectAsState(initial = emptyList())
    val sorted = remember(projects) { projects.sortedByName() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Projects") },
        text = {
            Column {
                if (sorted.isEmpty()) Text("Create a project in the Projects tab first.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                for (project in sorted) {
                    val fromNote = project.id in inherited && project.id !in assigned
                    Row(
                        Modifier.fillMaxWidth().clickable(enabled = !fromNote) { onToggle(project.id) }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = project.id in assigned || fromNote, onCheckedChange = { onToggle(project.id) }, enabled = !fromNote,
                            colors = CheckboxDefaults.colors(checkedColor = Brand.project),
                        )
                        Text(project.name)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

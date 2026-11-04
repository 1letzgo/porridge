package de.letzgo.porridge.ui.notes

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import de.letzgo.porridge.data.MeetingPdf
import de.letzgo.porridge.logic.MeetingExport
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.ui.Brand
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** iOS: `MeetingExportSheet` — Zusammenfassung und Transkript einzeln wählbar, als Textdatei oder formatiertes PDF. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MeetingExportSheet(note: Note, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val coroutines = rememberCoroutineScope()
    val hasSummary = !note.summary.isNullOrEmpty()
    val hasTranscript = note.segments.isNotEmpty()
    var summary by remember { mutableStateOf(hasSummary) }
    var transcript by remember { mutableStateOf(hasTranscript) }
    var format by remember { mutableStateOf(MeetingExport.Format.PDF) }
    var failed by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Export", style = MaterialTheme.typography.titleLarge)
            ChoiceRow("Summary", summary, hasSummary) { summary = it }
            HorizontalDivider(thickness = 0.5.dp)
            ChoiceRow("Transcript", transcript, hasTranscript) { transcript = it }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                MeetingExport.Format.entries.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = format == option, onClick = { format = option },
                        shape = SegmentedButtonDefaults.itemShape(index, MeetingExport.Format.entries.size),
                        colors = SegmentedButtonDefaults.colors(activeContainerColor = Brand.sky.copy(alpha = 0.18f), activeContentColor = Brand.navy),
                        icon = {},
                    ) { Text(option.title) }
                }
            }
            if (failed) Text("The file could not be written.", color = Brand.danger, style = MaterialTheme.typography.bodySmall)
            else if (!hasSummary && !hasTranscript) Text("This meeting has no summary or transcript yet.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            Button(
                enabled = summary || transcript, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Brand.sky.copy(alpha = 0.18f), contentColor = Brand.navy),
                onClick = {
                    coroutines.launch {
                        val export = MeetingExport.of(note, summary, transcript)
                        val file = withContext(Dispatchers.Default) { runCatching { write(context, export, format) }.getOrNull() }
                        failed = file == null
                        if (file != null) share(context, file, format)
                    }
                },
            ) { Text("Export") }
        }
    }
}

@Composable
private fun ChoiceRow(title: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked, onChange, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = Brand.sky))
    }
}

/** Im Cache, damit nichts liegen bleibt; der FileProvider gibt ihn für das Teilen frei (`res/xml/update_paths.xml`). */
private fun write(context: Context, export: MeetingExport, format: MeetingExport.Format): File {
    val folder = File(context.cacheDir, "exports").apply { deleteRecursively(); mkdirs() }
    val file = File(folder, "${export.fileName}.${format.extension}")
    when (format) {
        MeetingExport.Format.TEXT -> file.writeText(export.plainText)
        MeetingExport.Format.PDF -> MeetingPdf.write(export, file)
    }
    return file
}

private fun share(context: Context, file: File, format: MeetingExport.Format) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
    val send = Intent(Intent.ACTION_SEND).setType(format.mime).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, "Export"))
}

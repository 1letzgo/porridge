package de.letzgo.porridge.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import de.letzgo.porridge.logic.editor.NoteBlock
import de.letzgo.porridge.logic.editor.NoteMarkdown
import de.letzgo.porridge.ui.Brand

/**
 * iOS: `MarkdownText` (Views/Components/MarkdownText.swift) — zeigt Markdown (Zusammenfassungen): Überschriften,
 * Listen, Checklisten (antippbar über [onToggleTask] mit dem Zeilenindex), Zitate, fett und kursiv.
 */
@Composable
fun MarkdownText(markdown: String, modifier: Modifier = Modifier, onToggleTask: ((Int) -> Unit)? = null) {
    val blocks = NoteBlock.parse(markdown)
    val numbers = NoteBlock.numbers(blocks)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        blocks.forEachIndexed { index, block ->
            val indent = (block.indent * 18).dp
            when (val kind = block.kind) {
                is NoteBlock.Kind.Heading -> Text(
                    inline(block.text), modifier = Modifier.padding(top = if (index == 0) 0.dp else 10.dp),
                    style = when (kind.level) { 1 -> MaterialTheme.typography.titleLarge; 2 -> MaterialTheme.typography.titleMedium; else -> MaterialTheme.typography.titleSmall }
                        .copy(fontWeight = FontWeight.Bold, color = Brand.navy.takeIf { !androidx.compose.foundation.isSystemInDarkTheme() } ?: MaterialTheme.colorScheme.onSurface),
                )
                NoteBlock.Kind.Bullet, NoteBlock.Kind.Numbered -> Row(Modifier.padding(start = indent)) {
                    Text(if (kind == NoteBlock.Kind.Bullet) "•" else "${numbers[index]}.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(22.dp))
                    Text(inline(block.text), style = MaterialTheme.typography.bodyLarge)
                }
                is NoteBlock.Kind.Checklist -> Row(
                    Modifier.padding(start = indent).let { if (onToggleTask != null) it.clickable { onToggleTask(index) } else it },
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        if (kind.checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle, contentDescription = if (kind.checked) "Done" else "Open",
                        tint = if (kind.checked) Brand.sky else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 2.dp, end = 8.dp).size(20.dp),
                    )
                    Text(
                        inline(block.text), style = MaterialTheme.typography.bodyLarge,
                        color = if (kind.checked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                        textDecoration = if (kind.checked) TextDecoration.LineThrough else null,
                    )
                }
                NoteBlock.Kind.Quote -> Text(inline(block.text), style = MaterialTheme.typography.bodyLarge.copy(fontStyle = FontStyle.Italic), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp))
                NoteBlock.Kind.Paragraph -> if (block.text.isNotBlank()) Text(inline(block.text), style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

/** Fett und kursiv einer Zeile als AnnotatedString (gleiche Paar-Regel wie im Editor). */
fun inline(text: String): AnnotatedString = buildAnnotatedString {
    for ((run, bold, italic) in NoteMarkdown.inline(text)) {
        withStyle(SpanStyle(fontWeight = if (bold) FontWeight.Bold else null, fontStyle = if (italic) FontStyle.Italic else null)) { append(run) }
    }
}

package de.letzgo.porridge.data

import java.io.ByteArrayInputStream
import java.io.File
import java.util.zip.ZipInputStream

/**
 * iOS: `DocumentText` (Services/DocumentText.swift) — liest den Text aus Office-Dokumenten, auf dem Gerät: Word (.docx
 * und das ältere .doc), OpenDocument (.odt) und Rich Text (.rtf). Genug zum Suchen und Zusammenfassen; Layout, Bilder
 * und die Form von Tabellen bleiben zurück.
 */
object DocumentText {
    /** Größere Dateien werden nicht gelesen: Sie lägen ganz im Speicher. */
    const val MAX_BYTES = 40_000_000L
    private val extensions = setOf("docx", "docm", "dotx", "odt", "doc", "dot", "rtf")

    /** Der Text des Dokuments, oder "" wenn es keine der hier gelesenen Arten ist. */
    fun read(file: File): String {
        val extension = file.extension.lowercase()
        if (extension !in extensions || file.length() >= MAX_BYTES) return ""
        val data = file.readBytes()
        return when (extension) {
            "docx", "docm", "dotx" -> wordXmlText(zipEntry("word/document.xml", data))
            "odt" -> openDocumentText(zipEntry("content.xml", data))
            "rtf" -> richText(data)
            else -> wordBinaryText(data)
        }
    }

    // Word (.docx) und OpenDocument (.odt): XML in einem Zip

    fun wordXmlText(xml: ByteArray?): String {
        val text = xml?.toString(Charsets.UTF_8) ?: return ""
        return plain(text.replace("</w:p>", "\n").replace(Regex("<w:(br|cr)\\b[^>]*/>"), "\n").replace(Regex("<w:tab\\b[^>]*/>"), "\t"))
    }

    fun openDocumentText(xml: ByteArray?): String {
        val text = xml?.toString(Charsets.UTF_8) ?: return ""
        return plain(text.replace(Regex("</text:(p|h)>"), "\n").replace(Regex("<text:line-break\\b[^>]*/>"), "\n").replace(Regex("<text:tab\\b[^>]*/>"), "\t"))
    }

    /** Nimmt die Tags heraus und löst die Entitäten auf, die XML immer kennt. */
    private fun plain(xml: String): String =
        xml.replace(Regex("<[^>]+>"), "").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&").trim()

    /** Eine Datei aus einem Zip-Archiv. Null, wenn sie fehlt oder das Archiv beschädigt ist. */
    fun zipEntry(name: String, data: ByteArray): ByteArray? = runCatching {
        ZipInputStream(ByteArrayInputStream(data)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: return@use null
                if (entry.name == name) return@use zip.readBytes().takeIf { it.size < MAX_BYTES }
            }
            @Suppress("UNREACHABLE_CODE") null
        }
    }.getOrNull()

    // Rich Text

    /** Der Text einer RTF-Datei: ohne die Gruppen für Schriften, Farben und Bilder, ohne Steuerwörter. */
    fun richText(data: ByteArray): String {
        val source = data.toString(Charsets.ISO_8859_1)
        val text = StringBuilder()
        var depth = 0
        // Gruppen, deren Inhalt kein Text des Dokuments ist, werden ganz übersprungen.
        var skipBelow = Int.MAX_VALUE
        var i = 0
        while (i < source.length) {
            val c = source[i]
            when {
                c == '{' -> { depth++; i++ }
                c == '}' -> { if (depth <= skipBelow) skipBelow = Int.MAX_VALUE; depth--; i++ }
                c == '\\' && i + 1 < source.length -> {
                    val next = source[i + 1]
                    when {
                        next == '\'' && i + 3 < source.length -> {
                            // Ein Zeichen aus Windows Latin 1, als zwei Hex-Ziffern.
                            val code = source.substring(i + 2, i + 4).toIntOrNull(16)
                            if (code != null && depth < skipBelow) text.append(byteArrayOf(code.toByte()).toString(charset("windows-1252")))
                            i += 4
                        }
                        next == '\\' || next == '{' || next == '}' -> { if (depth < skipBelow) text.append(next); i += 2 }
                        next == '*' -> { skipBelow = minOf(skipBelow, depth); i += 2 }
                        next == '\n' || next == '\r' -> { if (depth < skipBelow) text.append('\n'); i += 2 }
                        next.isLetter() -> {
                            var j = i + 1
                            while (j < source.length && source[j].isLetter()) j++
                            val word = source.substring(i + 1, j)
                            var k = j
                            if (k < source.length && (source[k] == '-' || source[k].isDigit())) { k++; while (k < source.length && source[k].isDigit()) k++ }
                            val number = source.substring(j, k).toIntOrNull()
                            if (k < source.length && source[k] == ' ') k++
                            when (word) {
                                "par", "line", "page", "sect", "row" -> if (depth < skipBelow) text.append('\n')
                                "tab", "cell" -> if (depth < skipBelow) text.append('\t')
                                // Ein Unicode-Zeichen; das Ersatzzeichen dahinter entfällt.
                                "u" -> if (number != null) {
                                    if (depth < skipBelow) text.append((if (number < 0) number + 65536 else number).toChar())
                                    if (k < source.length && source[k] == '\\' && k + 1 < source.length && source[k + 1] == '\'') k += 4 else if (k < source.length && source[k] != '\\' && source[k] != '{' && source[k] != '}') k++
                                }
                                "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "object", "themedata", "datastore" -> skipBelow = minOf(skipBelow, depth)
                            }
                            i = k
                        }
                        else -> i += 2
                    }
                }
                c == '\r' || c == '\n' -> i++
                else -> { if (depth < skipBelow) text.append(c); i++ }
            }
        }
        return text.toString().trim()
    }

    // Word 97–2003 (.doc)

    private val windowsLatin = intArrayOf(
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    )

    /**
     * Der Text einer alten Word-Datei. Die Datei hält ihren Text am Stück, als UTF-16 oder als Windows Latin 1, zwischen
     * Tabellen der Formatierung: Die langen Textläufe sind das Dokument. Kurze (Schriftnamen, Eigenschaften) bleiben weg.
     */
    fun wordBinaryText(data: ByteArray): String {
        val wide = runs(data.size / 2, 24) { (data[it * 2].toInt() and 0xFF) or ((data[it * 2 + 1].toInt() and 0xFF) shl 8) }
        val narrow = runs(data.size, 48) { index ->
            val byte = data[index].toInt() and 0xFF
            // Windows Latin 1: 0x80–0x9F sind Anführungszeichen, Striche und das Eurozeichen.
            if (byte in 0x80..0x9F) windowsLatin[byte - 0x80] else byte
        }
        return (if (wide.length >= narrow.length) wide else narrow).trim()
    }

    /**
     * Die Textläufe unter [count] Zeichen, mit Zeilenumbrüchen verbunden. Ein Lauf ist Text, wenn er lang genug ist,
     * überwiegend aus Buchstaben und Leerzeichen besteht, Wörter hat (Leerzeichen) und nicht ein Zeichen immer wieder ist.
     */
    private fun runs(count: Int, shortest: Int, unit: (Int) -> Int): String {
        val result = StringBuilder()
        val run = StringBuilder()
        var letters = 0
        var spaces = 0
        val different = HashSet<Char>()
        fun flush() {
            if (run.length >= shortest && letters * 10 >= run.length * 6 && spaces * 40 >= run.length && different.size >= 8) {
                if (result.isNotEmpty()) result.append('\n')
                result.append(run)
            }
            run.setLength(0); letters = 0; spaces = 0; different.clear()
        }
        for (index in 0 until count) {
            when (val code = unit(index)) {
                0x0D, 0x0B, 0x0C, 0x0A -> if (run.isNotEmpty()) run.append('\n')
                0x07, 0x09 -> if (run.isNotEmpty()) run.append('\t')
                in 0x20..0x7E, in 0xA0..0x24F, in 0x2010..0x2026, 0x20AC, 0x2030, 0x2039, 0x203A, 0x2122, 0x0192, 0x02C6, 0x02DC -> {
                    val c = code.toChar()
                    run.append(c)
                    if (c == ' ') spaces++
                    if (c == ' ' || c.isLetter()) letters++
                    if (different.size < 8) different.add(c)
                }
                else -> flush()
            }
        }
        flush()
        return result.toString()
    }
}

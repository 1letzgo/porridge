package de.letzgo.porridge.logic

import java.text.BreakIterator
import java.util.Locale

/** iOS: `Paragraphs` (Design/Paragraphs.swift) — teilt Fließtext in kurze Absätze. */
object Paragraphs {
    /** Sätze ohne Leerraum am Rand (iOS: `enumerateSubstrings(options: .bySentences)`). */
    fun sentences(text: String): List<String> {
        val iterator = BreakIterator.getSentenceInstance(Locale.getDefault())
        iterator.setText(text)
        val result = mutableListOf<String>()
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            text.substring(start, end).trim().takeIf { it.isNotEmpty() }?.let { result += it }
            start = end
            end = iterator.next()
        }
        return result
    }

    /** Absätze aus höchstens `maxSentences` Sätzen (und etwa `maxLength` Zeichen); dazu die Satzzahl des letzten. */
    fun split(text: String, maxSentences: Int = 2, maxLength: Int = 220): Pair<List<String>, Int> {
        val paragraphs = mutableListOf<String>()
        var count = 0
        for (sentence in sentences(text)) {
            val last = paragraphs.lastOrNull()
            if (last != null && count < maxSentences && last.length + sentence.length < maxLength) {
                paragraphs[paragraphs.size - 1] = "$last $sentence"
                count++
            } else {
                paragraphs += sentence
                count = 1
            }
        }
        return paragraphs to count
    }

    /** Fasst Sätze zu Absätzen, mit einem Merker je Satz (zum Abblenden unbestätigten Texts). */
    fun <T> group(sentences: List<Pair<String, T>>, maxSentences: Int = 2, maxLength: Int = 220): List<List<Pair<String, T>>> {
        val paragraphs = mutableListOf<MutableList<Pair<String, T>>>()
        for (sentence in sentences) {
            val last = paragraphs.lastOrNull()
            if (last != null && last.size < maxSentences && last.sumOf { it.first.length } + sentence.first.length < maxLength) {
                last += sentence
            } else {
                paragraphs += mutableListOf(sentence)
            }
        }
        return paragraphs
    }

    /** Zum Speichern: Absätze durch eine Leerzeile getrennt. */
    fun format(text: String): String = split(text).first.joinToString("\n\n")
}

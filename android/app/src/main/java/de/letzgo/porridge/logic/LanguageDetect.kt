package de.letzgo.porridge.logic

/**
 * Ersatz für iOS `NLLanguageRecognizer` in `SummaryLanguage.detect`: zählt häufige Funktionswörter der neun
 * Sprachen aus `AppSettings.languages`. Liefert eine Sprache nur, wenn sie klar vorne liegt (wie iOS ab 0,6).
 */
object LanguageDetect {
    private val stopwords: Map<String, Set<String>> = mapOf(
        "de" to setOf("der", "die", "das", "und", "ist", "nicht", "ich", "wir", "sie", "es", "ein", "eine", "mit", "auf", "für", "auch", "dass", "aber", "noch", "wie", "dann", "den", "dem", "zu", "von", "haben", "wird", "sind", "oder", "schon"),
        "en" to setOf("the", "and", "is", "not", "we", "you", "it", "of", "to", "in", "that", "this", "for", "with", "are", "have", "be", "was", "but", "so", "what", "they", "will", "can", "there", "just", "about", "would", "our", "if"),
        "fr" to setOf("le", "la", "les", "et", "est", "pas", "je", "nous", "vous", "il", "elle", "un", "une", "des", "du", "que", "qui", "pour", "dans", "avec", "sur", "ce", "mais", "ou", "on", "au", "aux", "sont", "être", "avoir"),
        "es" to setOf("el", "la", "los", "las", "y", "es", "no", "yo", "nosotros", "que", "de", "en", "un", "una", "por", "para", "con", "pero", "como", "del", "se", "lo", "su", "más", "está", "son", "muy", "también", "hay", "esto"),
        "it" to setOf("il", "lo", "la", "gli", "le", "e", "è", "non", "io", "noi", "che", "di", "un", "una", "per", "con", "ma", "come", "del", "della", "sono", "anche", "questo", "nel", "alla", "si", "più", "ci", "ho", "hanno"),
        "nl" to setOf("de", "het", "een", "en", "is", "niet", "ik", "wij", "we", "jij", "dat", "die", "van", "op", "voor", "met", "maar", "ook", "zijn", "er", "naar", "als", "nog", "wat", "dit", "hebben", "wordt", "kan", "geen", "om"),
        "pt" to setOf("o", "a", "os", "as", "e", "é", "não", "eu", "nós", "que", "de", "em", "um", "uma", "para", "com", "mas", "como", "do", "da", "dos", "se", "por", "mais", "está", "são", "também", "isso", "muito", "você"),
        "pl" to setOf("i", "w", "nie", "to", "jest", "się", "na", "że", "z", "do", "ja", "my", "co", "jak", "ale", "tak", "o", "po", "od", "czy", "już", "są", "przez", "dla", "też", "ten", "ta", "jego", "być", "tylko"),
    )

    /** Sprachcode oder null, wenn der Text zu kurz oder nicht eindeutig ist. */
    fun detect(text: String): String? {
        val tokens = text.take(8000).lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        if (tokens.size < 5) return null
        val scores = stopwords.mapValues { (_, words) -> tokens.count { it in words }.toDouble() }
        val total = scores.values.sum()
        val best = scores.maxByOrNull { it.value } ?: return null
        if (best.value < 3 || total == 0.0) return null
        return best.key.takeIf { best.value / total >= 0.6 }
    }
}

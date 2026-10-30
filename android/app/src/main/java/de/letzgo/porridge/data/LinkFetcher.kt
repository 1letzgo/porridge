package de.letzgo.porridge.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.net.URI
import java.nio.charset.Charset
import java.util.concurrent.TimeUnit

/** iOS: `LinkFetcher` (Services/LinkFetcher.swift) — lädt eine Webseite und schneidet den lesbaren Text heraus. */
object LinkFetcher {
    data class Page(val title: String?, val text: String)

    class FetchError(message: String) : Exception(message)

    private const val MAX_LENGTH = 60_000

    suspend fun fetch(address: String): Page = withContext(Dispatchers.IO) {
        val scheme = runCatching { URI(address).scheme?.lowercase() }.getOrNull()
        if (scheme != "http" && scheme != "https") throw FetchError("This is not a web address.")
        val client = Net.client.newBuilder().callTimeout(25, TimeUnit.SECONDS).build()
        val request = Request.Builder().url(address)
            .header("User-Agent", "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36")
            .header("Accept", "text/html,application/xhtml+xml")
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw FetchError("The server answered ${response.code}.")
            val type = response.header("Content-Type")?.lowercase().orEmpty()
            // PDFs, Bilder und dergleichen: nichts zu lesen.
            if (type.isNotEmpty() && "html" !in type && "text/plain" !in type) return@withContext Page(null, "")
            val html = decode(response.body.bytes(), type)
            if ("text/plain" in type) Page(null, html.take(MAX_LENGTH)) else extract(html)
        }
    }

    private fun decode(data: ByteArray, contentType: String): String {
        val name = Regex("charset=([A-Za-z0-9_-]+)").find(contentType)?.groupValues?.get(1)
        val charset = name?.let { runCatching { Charset.forName(it) }.getOrNull() } ?: Charsets.UTF_8
        return String(data, charset)
    }

    private val flags = setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)

    private fun replace(pattern: String, text: String, with: String = " ") = Regex(pattern, flags).replace(text, with)

    private fun firstMatch(pattern: String, text: String): String? = Regex(pattern, flags).find(text)?.groupValues?.getOrNull(1)

    private fun meta(property: String, html: String): String? =
        firstMatch("""<meta[^>]+(?:property|name)=["']$property["'][^>]+content=["']([^"']*)["']""", html)
            ?: firstMatch("""<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']$property["']""", html)

    fun extract(html: String): Page {
        val rawTitle = meta("og:title", html) ?: firstMatch("<title[^>]*>(.*?)</title>", html)
        val title = rawTitle?.let { clean(decodeEntities(it)) }?.ifEmpty { null }

        var body = html
        for (tag in listOf("script", "style", "noscript", "svg", "template", "iframe", "nav", "footer", "header", "form", "aside")) {
            body = replace("<$tag\\b[^>]*>.*?</$tag>", body)
        }
        body = replace("<!--.*?-->", body)
        // Der Artikel selbst, wenn die Seite ihn auszeichnet.
        for (tag in listOf("article", "main")) {
            val inner = firstMatch("<$tag\\b[^>]*>(.*?)</$tag>", body)
            if (inner != null && inner.length > 600) { body = inner; break }
        }
        body = replace("<br\\s*/?>", body, "\n")
        body = replace("</(p|div|h[1-6]|li|tr|blockquote|section|pre)>", body, "\n")
        body = replace("<[^>]+>", body, "")
        body = decodeEntities(body)

        val lines = mutableListOf<String>()
        for (raw in body.split("\n")) {
            val line = clean(raw)
            // Menüs und Knöpfe sind kurze Zeilen; Sätze und längere Überschriften bleiben.
            val last = line.lastOrNull()
            if (line.length >= 25 || (line.length >= 8 && last != null && !isPunctuation(last) && lines.lastOrNull()?.endsWith(":") == true)) {
                lines += line
            }
        }
        var text = lines.joinToString("\n\n")
        if (text.length < 200) {
            (meta("og:description", html) ?: meta("description", html))?.let { description ->
                val summary = clean(decodeEntities(description))
                if (summary.isNotEmpty()) text = summary + (if (text.isEmpty()) "" else "\n\n$text")
            }
        }
        return Page(title, text.take(MAX_LENGTH))
    }

    private fun isPunctuation(c: Char) = when (Character.getType(c).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION -> true
        else -> false
    }

    private fun clean(text: String) = text.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    private val entities = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ",
        "auml" to "ä", "ouml" to "ö", "uuml" to "ü", "Auml" to "Ä", "Ouml" to "Ö", "Uuml" to "Ü", "szlig" to "ß",
        "ndash" to "–", "mdash" to "—", "hellip" to "…", "laquo" to "«", "raquo" to "»", "lsquo" to "‘", "rsquo" to "’",
        "ldquo" to "“", "rdquo" to "”", "euro" to "€", "copy" to "©", "middot" to "·", "bull" to "•",
        "eacute" to "é", "egrave" to "è", "agrave" to "à", "ccedil" to "ç", "aacute" to "á", "oacute" to "ó",
    )

    fun decodeEntities(text: String): String {
        if ('&' !in text) return text
        return Regex("&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);").replace(text) { match ->
            val name = match.groupValues[1]
            val code = when {
                name.startsWith("#x") -> name.drop(2).toIntOrNull(16)
                name.startsWith("#") -> name.drop(1).toIntOrNull()
                else -> null
            }
            when {
                code != null && Character.isValidCodePoint(code) -> String(Character.toChars(code))
                code == null && name in entities -> entities.getValue(name)
                else -> match.value
            }
        }
    }
}

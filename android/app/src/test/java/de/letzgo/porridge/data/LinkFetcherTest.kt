package de.letzgo.porridge.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkFetcherTest {
    @Test fun extractsArticleAndTitle() {
        val sentence = "Dies ist ein langer Satz über Haferbrei &amp; Löffel, der sicher lang genug ist."
        val html = """
            <html><head><meta property="og:title" content="Brei &ndash; Rezept"><title>x</title></head>
            <body><nav>Menü Startseite</nav><script>var a = 1;</script>
            <article><h2>Zutaten:</h2><p>Hafer</p><p>$sentence</p>${"<p>$sentence</p>".repeat(8)}</article>
            <footer>Impressum</footer></body></html>
        """.trimIndent()
        val page = LinkFetcher.extract(html)
        assertEquals("Brei – Rezept", page.title)
        assertTrue(page.text.startsWith("Dies ist ein langer Satz über Haferbrei & Löffel"))
        assertTrue("Menü" !in page.text && "Impressum" !in page.text && "var a" !in page.text)
    }

    @Test fun shortPagesGetTheDescription() {
        val page = LinkFetcher.extract("""<meta name="description" content="Kurz &#x2013; und &#228;hnlich"><p>Hi</p>""")
        assertEquals("Kurz – und ähnlich", page.text)
    }
}

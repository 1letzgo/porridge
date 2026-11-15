package de.letzgo.porridge.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

/** iOS: `DocumentTextTests` — dieselben Fälle. */
class DocumentTextTest {
    /** Ein kleines .docx (ein Zip mit gepacktem `word/document.xml`). */
    private val docx = "UEsDBBQAAAAIANOubl3HHBc8CgAAAAgAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbLMJqSxILda3AwBQSwMEFAAAAAgA065uXT843Th4AAAAwQAAABEAAAB3b3JkL2RvY3VtZW50LnhtbLOxr8jNUShLLSrOzM+zVTLUM1Cyt7Mpt0rJTy7NTc0rAbGT8lMqQXQBiCgCESV2AUX5JfnZ+Tk5CimpRQrBmSVVpXnpNvogKRBZBCYL0HW5Fx3ednh+qoJaYm6BtcLhOUkITUAiMUkfosw1LyUVi1n6MKfoI7kPAFBLAQIUAxQAAAAIANOubl3HHBc8CgAAAAgAAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgA065uXT843Th4AAAAwQAAABEAAAAAAAAAAAAAAIABOwAAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAACAAIAgAAAAOIAAAAAAA=="

    @Test fun aWordDocumentGivesItsParagraphs() {
        val data = Base64.getDecoder().decode(docx)
        assertEquals("Protokoll der Sitzung\nGröße & Übung\tEnde", DocumentText.wordXmlText(DocumentText.zipEntry("word/document.xml", data)))
        assertNull(DocumentText.zipEntry("missing.xml", data))
        assertNull(DocumentText.zipEntry("word/document.xml", "not a zip".toByteArray()))
    }

    @Test fun anOpenDocumentGivesItsParagraphs() {
        val xml = "<office:text><text:h>Titel</text:h><text:p>Erster &lt;Absatz&gt;</text:p><text:p>Zweiter</text:p></office:text>".toByteArray()
        assertEquals("Titel\nErster <Absatz>\nZweiter", DocumentText.openDocumentText(xml))
    }

    @Test fun anOldWordFileGivesItsTextWithoutTheTablesAroundIt() {
        val sentence = "Der Vorstand wird für zwei Jahre gewählt – Größe, Übung, Straße."
        val filler = ByteArray(600) { 0xFF.toByte() } + ByteArray(32) { it.toByte() }
        val fonts = "Times New Roman".toByteArray() + byteArrayOf(0, 1, 2)
        val wide = filler + sentence.toByteArray(Charsets.UTF_16LE) + byteArrayOf(0, 0, 1, 0) + fonts
        assertEquals(sentence, DocumentText.wordBinaryText(wide))
        val narrow = filler + sentence.toByteArray(charset("windows-1252")) + byteArrayOf(0, 1, 2) + fonts
        assertEquals(sentence, DocumentText.wordBinaryText(narrow))
        assertEquals("", DocumentText.wordBinaryText(filler + fonts))
    }

    @Test fun richTextGivesItsTextWithoutFontsAndControlWords() {
        val rtf = "{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}{\\colortbl;\\red0\\green0\\blue0;}\\f0\\fs24 Protokoll\\par Gr\\'f6\\'dfe und \\u220 ?bung\\tab Ende}"
        assertEquals("Protokoll\nGröße und Übung\tEnde", DocumentText.richText(rtf.toByteArray(Charsets.ISO_8859_1)))
    }
}

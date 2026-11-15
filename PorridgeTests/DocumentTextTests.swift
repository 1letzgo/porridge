import XCTest
@testable import Porridge

/// The same cases as Android's `DocumentTextTest`.
final class DocumentTextTests: XCTestCase {
    /// A small .docx (a zip with a deflated `word/document.xml`).
    private let docx = "UEsDBBQAAAAIANOubl3HHBc8CgAAAAgAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbLMJqSxILda3AwBQSwMEFAAAAAgA065uXT843Th4AAAAwQAAABEAAAB3b3JkL2RvY3VtZW50LnhtbLOxr8jNUShLLSrOzM+zVTLUM1Cyt7Mpt0rJTy7NTc0rAbGT8lMqQXQBiCgCESV2AUX5JfnZ+Tk5CimpRQrBmSVVpXnpNvogKRBZBCYL0HW5Fx3ednh+qoJaYm6BtcLhOUkITUAiMUkfosw1LyUVi1n6MKfoI7kPAFBLAQIUAxQAAAAIANOubl3HHBc8CgAAAAgAAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgA065uXT843Th4AAAAwQAAABEAAAAAAAAAAAAAAIABOwAAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAACAAIAgAAAAOIAAAAAAA=="

    func testAWordDocumentGivesItsParagraphs() throws {
        let data = try XCTUnwrap(Data(base64Encoded: docx))
        XCTAssertEqual(DocumentText.wordXMLText(DocumentText.zipEntry("word/document.xml", in: data)), "Protokoll der Sitzung\nGröße & Übung\tEnde")
        XCTAssertNil(DocumentText.zipEntry("missing.xml", in: data))
        XCTAssertNil(DocumentText.zipEntry("word/document.xml", in: Data("not a zip".utf8)))
    }

    func testAnOpenDocumentGivesItsParagraphs() {
        let xml = Data("<office:text><text:h>Titel</text:h><text:p>Erster &lt;Absatz&gt;</text:p><text:p>Zweiter</text:p></office:text>".utf8)
        XCTAssertEqual(DocumentText.openDocumentText(xml), "Titel\nErster <Absatz>\nZweiter")
    }

    func testAnOldWordFileGivesItsTextWithoutTheTablesAroundIt() {
        let sentence = "Der Vorstand wird für zwei Jahre gewählt – Größe, Übung, Straße."
        let filler = Data(repeating: 0xFF, count: 600) + Data((0..<32).map { UInt8($0) })
        let fonts = Data("Times New Roman".utf8) + Data([0, 1, 2])
        // As UTF-16, the way Word writes text with signs beyond Latin 1 …
        let wide = filler + sentence.data(using: .utf16LittleEndian)! + Data([0, 0, 1, 0]) + fonts
        XCTAssertEqual(DocumentText.wordBinaryText(wide), sentence)
        // … and as Windows Latin 1, one byte a sign.
        let narrow = filler + sentence.data(using: .windowsCP1252)! + Data([0, 1, 2]) + fonts
        XCTAssertEqual(DocumentText.wordBinaryText(narrow), sentence)
        XCTAssertEqual(DocumentText.wordBinaryText(filler + fonts), "")
    }
}

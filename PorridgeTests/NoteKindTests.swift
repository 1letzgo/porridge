import XCTest
@testable import Porridge

/// Small rules of the home list and the search.
@MainActor
final class NoteKindTests: XCTestCase {
    private func shown(_ kind: SearchKind) -> [String] {
        let plain = Note()
        plain.title = "plain"
        let meeting = Note()
        meeting.title = "meeting"
        meeting.audioFileName = "a.m4a"
        let link = Note()
        link.title = "link"
        link.url = "https://example.com"
        let file = Note()
        file.title = "file"
        file.source = .share
        file.attachments = [Attachment(fileName: "a.pdf", name: "Invoice.pdf", kindRaw: "pdf")]
        let image = Note()
        image.title = "image"
        image.source = .share
        image.attachments = [Attachment(fileName: "c.png", name: "Screenshot.png", kindRaw: "image")]
        // A note with a file attached stays a note.
        let attached = Note()
        attached.title = "attached"
        attached.source = .note
        attached.attachments = [Attachment(fileName: "b.png", name: "Photo.png", kindRaw: "image")]
        return [plain, meeting, link, file, image, attached].filter(kind.matches).map(\.title)
    }

    func testKeepsOnlyItsKind() {
        XCTAssertEqual(shown(.meetings), ["meeting"])
        XCTAssertEqual(shown(.notes), ["plain", "attached"])
        XCTAssertEqual(shown(.links), ["link"])
        XCTAssertEqual(shown(.files), ["file"])
        XCTAssertEqual(shown(.images), ["image"])
    }

    func testThinkingIsRemoved() {
        XCTAssertEqual(LocalLLM.withoutThinking("<think>hm</think>\nAnswer"), "Answer")
        XCTAssertEqual(LocalLLM.withoutThinking("<|channel>thought\nhm<channel|>Answer"), "Answer")
        XCTAssertEqual(LocalLLM.withoutThinking("Answer<|channel>thought\nhm"), "Answer")
    }

    func testNemotronBoltStaysItsOwnModel() {
        XCTAssertEqual(LocalModel(rawValue: "nemotronBolt"), .nemotronBolt)
        XCTAssertEqual(LocalModel.nemotronBolt.repoID, "lmstudio-community/NVIDIA-Nemotron-3.5-Bolt-E4B-MLX-4bit")
    }
    func testRecordingNotesBecomeListItemsWithTheirTime() {
        let notes = [RecordingNote(at: 65, text: "Ask about pricing"), RecordingNote(at: 3725, text: "Send the plan")]
        XCTAssertEqual(RecordingNote.markdown(notes), "- \(TimeInterval(65).clockString) Ask about pricing\n- \(TimeInterval(3725).clockString) Send the plan")
        XCTAssertEqual(RecordingNote.markdown([]), "")
    }

    func testRecommendedModelFollowsTheMemory() {
        XCTAssertEqual(LocalModel.recommended(memoryGB: 12), .nemotronBolt)
        XCTAssertEqual(LocalModel.recommended(memoryGB: 8), .qwen3)
        XCTAssertEqual(LocalModel.recommended(memoryGB: 6), .qwen3Small)
    }
}

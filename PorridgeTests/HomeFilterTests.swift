import XCTest
@testable import Porridge

/// The same cases as Android's `HomeListLogicTest`.
@MainActor
final class HomeFilterTests: XCTestCase {
    private func shown(_ filter: HomeFilter) -> [String] {
        let plain = Note()
        plain.title = "plain"
        let meeting = Note()
        meeting.title = "meeting"
        meeting.audioFileName = "a.m4a"
        let link = Note()
        link.title = "link"
        link.url = "https://example.com"
        return [plain, meeting, link].filter(filter.matches).map(\.title)
    }

    func testKeepsOnlyItsKind() {
        XCTAssertEqual(shown(.all), ["plain", "meeting", "link"])
        XCTAssertEqual(shown(.meetings), ["meeting"])
        XCTAssertEqual(shown(.notes), ["plain"])
        XCTAssertEqual(shown(.links), ["link"])
        XCTAssertEqual(shown(.projects), [])
    }

    func testShowsProjectsOnlyWhereItSays() {
        XCTAssertEqual(HomeFilter.allCases.filter(\.showsProjects), [.all, .projects])
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
    func testElementLimitSharesFromTheTopDown() {
        let few = HomeList.elementLimits(pinned: 2, notes: 4, showAll: false)
        XCTAssertEqual([few.pinned, few.notes, few.hidden], [2, 4, 0])
        let many = HomeList.elementLimits(pinned: 2, notes: 40, showAll: false)
        XCTAssertEqual([many.pinned, many.notes, many.hidden], [2, 23, 17])
        let manyPinned = HomeList.elementLimits(pinned: 40, notes: 5, showAll: false)
        XCTAssertEqual([manyPinned.pinned, manyPinned.notes, manyPinned.hidden], [25, 0, 20])
    }

    func testElementLimitShowsAllWhenAskedAndStillCountsTheHidden() {
        let all = HomeList.elementLimits(pinned: 2, notes: 40, showAll: true)
        XCTAssertEqual([all.pinned, all.notes, all.hidden], [2, 40, 17])
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

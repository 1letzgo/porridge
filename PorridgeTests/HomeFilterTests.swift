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
        XCTAssertEqual(shown(.tasks), [])
        XCTAssertEqual(shown(.projects), [])
    }

    func testShowsProjectsAndTasksOnlyWhereItSays() {
        XCTAssertEqual(HomeFilter.allCases.filter(\.showsProjects), [.all, .projects])
        XCTAssertEqual(HomeFilter.allCases.filter(\.showsTasks), [.all, .tasks])
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
        let few = HomeList.elementLimits(pinned: 2, tasks: 3, notes: 4, showAll: false)
        XCTAssertEqual([few.pinned, few.tasks, few.notes, few.hidden], [2, 3, 4, 0])
        let many = HomeList.elementLimits(pinned: 2, tasks: 10, notes: 30, showAll: false)
        XCTAssertEqual([many.pinned, many.tasks, many.notes, many.hidden], [2, 10, 13, 17])
        let manyTasks = HomeList.elementLimits(pinned: 0, tasks: 40, notes: 5, showAll: false)
        XCTAssertEqual([manyTasks.pinned, manyTasks.tasks, manyTasks.notes, manyTasks.hidden], [0, 25, 0, 20])
    }

    func testElementLimitShowsAllWhenAskedAndStillCountsTheHidden() {
        let all = HomeList.elementLimits(pinned: 2, tasks: 10, notes: 30, showAll: true)
        XCTAssertEqual([all.pinned, all.tasks, all.notes, all.hidden], [2, 10, 30, 17])
    }

    func testRecordingNotesBecomeListItemsWithTheirTime() {
        let notes = [RecordingNote(at: 65, text: "Ask about pricing"), RecordingNote(at: 3725, text: "Send the plan")]
        XCTAssertEqual(RecordingNote.markdown(notes), "- \(TimeInterval(65).clockString) Ask about pricing\n- \(TimeInterval(3725).clockString) Send the plan")
        XCTAssertEqual(RecordingNote.markdown([]), "")
    }
}

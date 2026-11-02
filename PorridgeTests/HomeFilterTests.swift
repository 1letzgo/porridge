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
}

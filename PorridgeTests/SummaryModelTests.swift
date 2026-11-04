import XCTest
@testable import Porridge

@MainActor
final class SummaryModelTests: XCTestCase {
    private let keys = [AppSettings.externalModelsKey, AppSettings.billingKey, AppSettings.localModelKey, AppSettings.providerKey, "aiModel.anthropic"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        SummaryModel.external = []
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    func testAddingKeepsOneOfEachAndSurvivesReading() {
        let model = SummaryModel.cloud(.anthropic, "claude-haiku-5-5")
        SummaryModel.add(model)
        SummaryModel.add(model)
        XCTAssertEqual(SummaryModel.external, [model])
        SummaryModel.remove(model)
        XCTAssertEqual(SummaryModel.external, [])
    }

    func testTheDefaultCanBeEitherKind() {
        SummaryModel.current = .cloud(.anthropic, "claude-haiku-5-5")
        XCTAssertEqual(SummaryModel.current, .cloud(.anthropic, "claude-haiku-5-5"))
        XCTAssertEqual(AppSettings.billing, .byok)
        SummaryModel.current = .local(.qwen3)
        XCTAssertEqual(SummaryModel.current, .local(.qwen3))
        XCTAssertEqual(AppSettings.billing, .local)
    }

    func testRemovingTheDefaultDoesNotLeaveItBehind() {
        let first = SummaryModel.cloud(.anthropic, "a")
        let second = SummaryModel.cloud(.anthropic, "b")
        SummaryModel.add(first)
        SummaryModel.add(second)
        SummaryModel.current = first
        SummaryModel.remove(first)
        XCTAssertNotEqual(SummaryModel.current, first)
        XCTAssertTrue(SummaryModel.available.contains(SummaryModel.current))
    }

    func testNamesAreTheSameAsNextToAFinishedSummary() {
        XCTAssertEqual(SummaryModel.local(.qwen3).label, "Qwen3 4B (on-device)")
        XCTAssertEqual(SummaryModel.cloud(.anthropic, "x").label, "Anthropic · x")
        XCTAssertEqual(SummaryModel.cloud(.anthropic, "claude-haiku-5-5").name, "Claude Haiku 5.5")
    }

    func testAModelFromBeforeTheListIsCarriedOver() {
        UserDefaults.standard.removeObject(forKey: AppSettings.externalModelsKey)
        SummaryModel.current = .cloud(.anthropic, "claude-haiku-5-5")
        XCTAssertTrue(SummaryModel.external.contains(.cloud(.anthropic, "claude-haiku-5-5")))
        // Once there is a list it is what counts: removing stays removed.
        SummaryModel.external = []
        XCTAssertEqual(SummaryModel.external, [])
    }
}

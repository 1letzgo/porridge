import XCTest
@testable import Porridge

/// The chat's own model ("Chat Model"): which one answers, the fallback to the default, how much context each kind
/// of model gets, and how a failed request reads in the chat.
@MainActor
final class ChatModelTests: XCTestCase {
    private let qwen = SummaryModel.local(.qwen35)
    private let apple = SummaryModel.local(.apple)
    private let claude = SummaryModel.cloud(.anthropic, "claude-sonnet-4-5")
    private let gpt = SummaryModel.cloud(.openAI, "gpt-5")

    private func resolve(_ stored: String?, available: [SummaryModel], usable: Set<SummaryModel>? = nil) -> SummaryModel {
        SummaryModel.resolveChat(stored: stored, available: available, isUsable: { usable?.contains($0) ?? true }, fallback: qwen)
    }

    func testTheChatUsesItsOwnModelOrTheDefault() {
        let list = [qwen, apple, claude, gpt]
        XCTAssertEqual(resolve(nil, available: list), qwen, "nothing chosen: Same as Default")
        XCTAssertEqual(resolve("", available: list), qwen)
        XCTAssertEqual(resolve(claude.id, available: list), claude, "an external model")
        XCTAssertEqual(resolve(apple.id, available: list), apple, "another on-device model")
    }

    func testAModelThatIsGoneFallsBackQuietly() {
        XCTAssertEqual(resolve(claude.id, available: [qwen, gpt]), qwen, "removed from the list")
        XCTAssertEqual(resolve(claude.id, available: [qwen, claude], usable: [qwen]), qwen, "its key was taken away")
        XCTAssertEqual(resolve(SummaryModel.local(.qwen3).id, available: [qwen]), qwen, "deleted from the device")
    }

    func testTheChoiceIsStoredOnThisDevice() {
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: AppSettings.chatModelKey)
        defer { defaults.set(before, forKey: AppSettings.chatModelKey) }
        SummaryModel.chatChoice = nil
        XCTAssertNil(defaults.string(forKey: AppSettings.chatModelKey))
        XCTAssertEqual(SummaryModel.chat, SummaryModel.current)
        defaults.set(claude.id, forKey: AppSettings.chatModelKey)
        XCTAssertEqual(defaults.string(forKey: AppSettings.chatModelKey), "cloud:anthropic:claude-sonnet-4-5")
        if !SummaryModel.available.contains(claude) {
            XCTAssertNil(SummaryModel.chatChoice, "a model not in the list is no choice")
            XCTAssertEqual(SummaryModel.chat, SummaryModel.current)
        }
    }

    func testOnlyCloudModelsSayWhatLeavesTheDevice() {
        XCTAssertNil(qwen.sendsHint("question"))
        XCTAssertEqual(claude.sendsHint("question and excerpts of your notes"), "The question and excerpts of your notes goes to Anthropic.")
        XCTAssertEqual(SummaryModel.cloud(.custom, "llama").sendsHint("question"), "The question goes to your server.")
    }

    // MARK: - Room

    func testEachKindOfModelGetsItsRoom() {
        XCTAssertEqual(ChatBudget.for(apple), .small)
        XCTAssertEqual(ChatBudget.for(qwen), .standard)
        XCTAssertEqual(ChatBudget.for(claude), .large)
        XCTAssertEqual(ChatBudget.small.promptLimit, 7000)
        XCTAssertGreaterThan(ChatBudget.large.fillBudget, ChatBudget.standard.fillBudget)
    }

    func testACloudModelSeesMoreOfTheNotes() {
        let notes = (1...60).map { index -> Note in
            let note = Note()
            note.title = "Hafer \(index)"
            note.text = "Hafer wächst auf Feld \(index). " + String(repeating: "Mehr über Hafer und Felder. ", count: 10)
            return note
        }
        let documents = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, ChatDocument(note: $0)) })
        let chunks = ChatRetrieval.chunks(from: notes)
        func context(_ budget: ChatBudget) -> ChatContext {
            ChatRetrieval.context("Was weiß ich über Hafer?", documents: documents, chunks: chunks, bucketNames: [:], budget: budget)
        }
        let standard = context(.standard).items.count
        let large = context(.large).items.count
        XCTAssertEqual(standard, 10)
        XCTAssertEqual(large, 30)

        let listing = ChatRetrieval.context("Welche Links gibt es?", documents: Dictionary(uniqueKeysWithValues: notes.map { note -> (UUID, ChatDocument) in
            note.url = "https://example.com/\(note.title)"
            return (note.id, ChatDocument(note: note))
        }), chunks: chunks, bucketNames: [:], budget: .large)
        XCTAssertEqual(listing.items.filter(\.isListing).count, 60, "all 60 links are listed for a cloud model")
    }

    // MARK: - Errors

    func testAFailedRequestSaysWhatToDo() {
        XCTAssertEqual(CloudLLM.error(status: 401, message: "invalid x-api-key", provider: .anthropic).errorDescription,
                       "Anthropic did not accept the API key. Check it in Settings, under AI.")
        XCTAssertEqual(CloudLLM.error(status: 429, message: "rate", provider: .openAI).errorDescription,
                       "OpenAI is busy or your usage limit is reached. Try again later.")
        XCTAssertTrue(CloudLLM.error(status: 503, message: "x", provider: .custom).errorDescription?.hasPrefix("Your server has a problem") ?? false)
        XCTAssertEqual(CloudLLM.error(status: 400, message: "model not found", provider: .openRouter).errorDescription, "OpenRouter: model not found")

        XCTAssertEqual(ChatService.message(for: URLError(.notConnectedToInternet), model: claude),
                       "Could not reach Anthropic. Check the internet connection and try again.")
        XCTAssertEqual(ChatService.message(for: URLError(.timedOut), model: claude), "Anthropic took too long to answer. Try again in a moment.")
        XCTAssertEqual(ChatService.message(for: SummaryError.missingAPIKey("Anthropic"), model: claude), "Please add your Anthropic API key in Settings.")
    }
}

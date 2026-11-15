import Foundation
import SwiftData

/// One conversation with the notes. Several are kept side by side; a chat can be about everything or about one bucket.
/// Chats stay on the device they were held on: they are not synced.
@Model
final class ChatThread {
    var id: UUID = UUID()
    /// The first question, shortened.
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// The bucket the chat is about (`Projects.key`); nil is all notes.
    var projectID: String?

    init(projectID: String? = nil) {
        self.id = UUID()
        self.projectID = projectID
    }
}

/// One message of a chat: a question, or the answer with the notes it was taken from.
@Model
final class ChatEntry {
    enum Role: String {
        case user, assistant
    }

    var id: UUID = UUID()
    /// The chat it belongs to (`ChatThread.id`).
    var threadID: UUID = UUID()
    var roleRaw: String = Role.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    /// The answer is an error message (no model, no connection).
    var isError: Bool = false
    /// The notes behind an answer, as JSON (`[ChatSource]`).
    var sourcesData: Data?

    var role: Role { Role(rawValue: roleRaw) ?? .user }

    var sources: [ChatSource] {
        get { sourcesData.flatMap { try? JSONDecoder().decode([ChatSource].self, from: $0) } ?? [] }
        set { sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(threadID: UUID, role: Role, text: String, isError: Bool = false) {
        self.id = UUID()
        self.threadID = threadID
        self.roleRaw = role.rawValue
        self.text = text
        self.isError = isError
    }
}

/// A note an answer was taken from.
struct ChatSource: Codable, Identifiable, Hashable {
    let noteID: UUID
    let title: String
    let date: Date
    var id: UUID { noteID }
}

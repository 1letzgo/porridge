import SwiftData
@testable import Porridge

/// A store in memory, the same models as the app's, never touching the app's data or iCloud.
@MainActor
enum TestStore {
    static func context() throws -> ModelContext {
        let schema = Schema([Meeting.self, Note.self, NoteFolder.self, VoiceProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: configuration))
    }
}

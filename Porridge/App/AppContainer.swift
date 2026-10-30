import SwiftData

enum AppContainer {
    /// SwiftData store synced through the private CloudKit database (container from the entitlements).
    static func make() -> ModelContainer {
        let schema = Schema([Meeting.self, Note.self, NoteFolder.self, VoiceProfile.self])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
        } catch {
            // Fall back to a local store, e.g. when iCloud is not configured.
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        }
    }
}

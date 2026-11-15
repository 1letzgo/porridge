import SwiftData

enum AppContainer {
    /// Set when the notes could not be opened and the app runs on an empty store in memory (see `make`).
    nonisolated(unsafe) private(set) static var storeError: String?

    /// SwiftData store, synced through the private CloudKit database (container from the entitlements) when
    /// iCloud is the chosen sync; otherwise local (Nextcloud syncs on its own, see `NextcloudSync`).
    static func make() -> ModelContainer {
        let schema = Schema([Meeting.self, Note.self, NoteFolder.self, VoiceProfile.self, ChatThread.self, ChatEntry.self])
        do {
            let cloud: ModelConfiguration.CloudKitDatabase = SyncMode.active == .iCloud ? .automatic : .none
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: cloud))
        } catch {
            // Fall back to a local store, e.g. when iCloud is not configured.
            do {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
            } catch {
                // The store itself cannot be opened (a migration that failed). Crashing here would do so at every
                // launch; the app starts on an empty store instead and says so. The notes stay untouched on disk.
                storeError = error.localizedDescription
                print("[store] could not be opened: \(error)")
                return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            }
        }
    }
}

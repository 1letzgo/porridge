import SwiftData

enum AppContainer {
    /// SwiftData store, synced through the private CloudKit database (container from the entitlements) when
    /// iCloud is the chosen sync; otherwise local (Nextcloud syncs on its own, see `NextcloudSync`).
    static func make() -> ModelContainer {
        let schema = Schema([ActionItem.self, Meeting.self, Note.self, NoteFolder.self, VoiceProfile.self])
        do {
            let cloud: ModelConfiguration.CloudKitDatabase = SyncMode.active == .iCloud ? .automatic : .none
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: cloud))
        } catch {
            // Fall back to a local store, e.g. when iCloud is not configured.
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        }
    }
}

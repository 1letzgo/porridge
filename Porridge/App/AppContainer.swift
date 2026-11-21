import Foundation
import SwiftData

/// Where the app keeps its files (Application Support). Debug builds started with the environment variable
/// `PORRIDGE_TEST_DATA=<folder>` keep everything there instead (store, recordings, files, chat index) and never sync,
/// so a test run never touches the real notes.
enum DataLocation {
    static let testFolder: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["PORRIDGE_TEST_DATA"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        return nil
        #endif
    }()

    static var applicationSupport: URL {
        testFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// Whether the notes sync through iCloud. Chosen in the settings; a change takes effect at the next launch
/// (the SwiftData store is set up with or without CloudKit when the app starts).
enum SyncMode: String, CaseIterable, Identifiable {
    case off
    case iCloud = "icloud"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .iCloud: "iCloud"
        }
    }

    static let key = "syncMode"

    /// The choice in the settings; iCloud for everyone who had the app before there was a choice, and for
    /// everyone who had chosen the Nextcloud sync of earlier versions (its value is no case any more).
    static var chosen: SyncMode {
        UserDefaults.standard.string(forKey: key).flatMap(SyncMode.init(rawValue:)) ?? .iCloud
    }

    /// The mode the app was started with; off on test data (`DataLocation.testFolder`).
    static let active = DataLocation.testFolder == nil ? chosen : .off
}

enum AppContainer {
    /// Set when the notes could not be opened and the app runs on an empty store in memory (see `make`).
    nonisolated(unsafe) private(set) static var storeError: String?

    /// SwiftData store, synced through the private CloudKit database (container from the entitlements) when
    /// iCloud sync is on; otherwise local only.
    static func make() -> ModelContainer {
        let schema = Schema([Meeting.self, Note.self, NoteFolder.self, VoiceProfile.self, ChatThread.self, ChatEntry.self])
        if let folder = DataLocation.testFolder {
            let url = folder.appendingPathComponent("test.store")
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        }
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
                return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            }
        }
    }
}

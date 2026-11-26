import CloudKit
import SwiftData
import SwiftUI

/// iOS wakes the app here when model downloads ended while it was not running.
final class PorridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The meeting notifications' Record and Join reach the app from a cold start too: their delegate is set
        // before launching ends, as iOS asks.
        MeetingNotifications.register()
        return true
    }

    /// The scenes get a delegate of their own: an invitation to a shared bowl arrives there.
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PorridgeSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The session tells iOS itself when it is done with its events.
        ModelBackgroundDownloads.shared.backgroundCompletion = completionHandler
    }
}

/// Takes invitations to shared bowls: a link opened while the app runs, or one that launched it.
final class PorridgeSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        Task { @MainActor in await BowlSharing.shared.accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in await BowlSharing.shared.accept(cloudKitShareMetadata) }
    }
}

@main
struct PorridgeApp: App {
    @UIApplicationDelegateAdaptor(PorridgeAppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var processing: ProcessingService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        let container = AppContainer.make()
        self.container = container
        _processing = State(initialValue: ProcessingService(container: container))
        // Finds the iCloud container off the main thread and moves the files of notes into it.
        MainActor.assumeIsolated { CloudFiles.start(container) }
        // Shared bowls: follows the zones of the bowls this person shares and of those shared with them.
        MainActor.assumeIsolated { BowlSharing.shared.start(container) }
        // Links between entries show the current title of the entry they point to.
        MainActor.assumeIsolated {
            let context = container.mainContext
            EntryLinks.install { id in
                var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return try? context.fetch(descriptor).first
            }
        }
        // Once: what the removed Plaud import left on this device (sign-in, settings, downloads).
        MainActor.assumeIsolated { PlaudCleanup.run() }
        #if DEBUG
        MainActor.assumeIsolated { TestSeed.run(container) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // `porridge://` links (EntryLinkRouter): `entry/<UUID>` opens that entry (links between entries,
                // the widgets); `new`, `meeting`, `inbox`, `todos` and `search?q=…` go to `QuickActionCenter`.
                .onOpenURL { EntryLinkRouter.handle($0) }
                .environment(processing)
                .environment(ModelManager.shared)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await ModelManager.shared.releaseLLM() }
                }
                .task {
                    await ModelManager.clearCompiledModelsAfterUpdate()
                    LiveRecording.endStale()
                    processing.resumePending()
                    // Alerts shortly before meetings, with Record (`MeetingAlerts`).
                    MeetingAlertScheduler.shared.start()
                    await ModelManager.shared.resumeBackgroundDownloads()
                    // Loading the model takes a while (Neural Engine compile): do it before the first dictation.
                    if TranscriptionEngine.asrInstalled || AppSettings.speechEngine == .apple {
                        try? await ModelManager.shared.ensureASR()
                    }
                }
        }
        .modelContainer(container)
        // The menu bar of an iPad (and the shortcuts of a hardware keyboard): New Note, the places, Search, Settings….
        .commands { PlaceCommands() }
        .onChange(of: scenePhase) { _, phase in
            // A big model in memory gets an app in the background ended first.
            if phase == .background { Task { await ModelManager.shared.releaseLLM() } }
            // "Back from Later" notifications planned before "Later" was taken away do not ring.
            if phase == .active { InboxSnooze.removePlannedNotifications() }
        }
    }
}

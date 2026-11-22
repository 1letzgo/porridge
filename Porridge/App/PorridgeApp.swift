import CloudKit
import SwiftData
import SwiftUI

/// iOS wakes the app here when model downloads ended while it was not running.
final class PorridgeAppDelegate: NSObject, UIApplicationDelegate {
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
        #if DEBUG
        MainActor.assumeIsolated { TestSeed.run(container) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(processing)
                .environment(ModelManager.shared)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await ModelManager.shared.releaseLLM() }
                }
                .task {
                    await ModelManager.clearCompiledModelsAfterUpdate()
                    LiveRecording.endStale()
                    processing.resumePending()
                    await ModelManager.shared.resumeBackgroundDownloads()
                    // Loading the model takes a while (Neural Engine compile): do it before the first dictation.
                    if TranscriptionEngine.asrInstalled || AppSettings.speechEngine == .apple {
                        try? await ModelManager.shared.ensureASR()
                    }
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // A big model in memory gets an app in the background ended first.
            if phase == .background { Task { await ModelManager.shared.releaseLLM() } }
        }
    }
}

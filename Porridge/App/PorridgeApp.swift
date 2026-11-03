import SwiftData
import SwiftUI

/// iOS wakes the app here when model downloads ended while it was not running.
final class PorridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ModelBackgroundDownloads.shared.backgroundCompletion = completionHandler
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
        NextcloudSync.shared.attach(container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(processing)
                .environment(ModelManager.shared)
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await ModelManager.shared.releaseLLM() }
                }
                #endif
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
            // Back in the app: pick up what the other devices did.
            if phase == .active { NextcloudSync.shared.syncSoon(after: .zero) }
            // A big model in memory gets an app in the background ended first.
            if phase == .background { Task { await ModelManager.shared.releaseLLM() } }
        }
    }
}

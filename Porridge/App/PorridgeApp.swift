import SwiftData
import SwiftUI

@main
struct PorridgeApp: App {
    private let container: ModelContainer
    @State private var processing: ProcessingService

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        let container = AppContainer.make()
        self.container = container
        _processing = State(initialValue: ProcessingService(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(processing)
                .environment(ModelManager.shared)
                .task {
                    LiveRecording.endStale()
                    processing.resumePending()
                    // Loading the model takes a while (Neural Engine compile): do it before the first dictation.
                    if TranscriptionEngine.asrInstalled || AppSettings.speechEngine == .apple {
                        try? await ModelManager.shared.ensureASR()
                    }
                }
        }
        .modelContainer(container)
    }
}

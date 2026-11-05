import AppKit
import SwiftData
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The shortcut works even when no window is open.
        DictationController.shared.reloadShortcut()
        AppUpdate.shared.start()
        // Loading the speech model takes a moment; do it before the first dictation.
        Task { @MainActor in
            if TranscriptionEngine.asrInstalled || AppSettings.speechEngine == .apple {
                try? await ModelManager.shared.ensureASR()
            }
        }
    }

    /// Back from System Settings: a permission may have been given in the meantime.
    func applicationDidBecomeActive(_ notification: Notification) {
        NextcloudSync.shared.syncSoon(after: .zero)
        if DictationController.shared.shortcutNeedsAccessibility || DictationController.shared.shortcutUnavailable {
            DictationController.shared.reloadShortcut()
        }
    }

    /// Closing the window keeps Porridge running in the menu bar, so the shortcut stays available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PorridgeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let container: ModelContainer
    @State private var processing: ProcessingService
    @State private var dictation = DictationController.shared
    @State private var update = AppUpdate.shared

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        DictationSettings.registerDefaults()
        let container = AppContainer.make()
        self.container = container
        _processing = State(initialValue: ProcessingService(container: container))
        NextcloudSync.shared.attach(container)
    }

    var body: some Scene {
        Window("Porridge", id: "main") {
            RootView()
                .environment(processing)
                .environment(ModelManager.shared)
                .frame(minWidth: 860, minHeight: 560)
                .task { processing.resumePending() }
                .updateAlert(update)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 720)
        .commands {
            PorridgeCommands()
            CommandGroup(after: .appInfo) {
                if AppUpdate.isEnabled {
                    Button("Check for Updates…") {
                        Task { await update.check(manual: true) }
                    }
                    .disabled(update.checking)
                }
            }
        }

        Settings {
            SettingsView(isEmbedded: true)
                .environment(processing)
                .environment(ModelManager.shared)
                .frame(width: 640, height: 760)
        }
        .modelContainer(container)

        MenuBarExtra {
            MenuBarContent(dictation: dictation, update: update)
        } label: {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
        }
    }
}

/// Every command of the toolbars in the menu bar too. What does not apply right now is dimmed, not hidden.
private struct PorridgeCommands: Commands {
    @FocusedValue(\.libraryActions) private var library
    @FocusedValue(\.noteActions) private var note
    @FocusedValue(\.homeFilter) private var filter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { NotificationCenter.default.post(name: .newNote, object: nil) }
                .keyboardShortcut("n")
            Button("Record Meeting") { library?.recordMeeting() }
                .keyboardShortcut("r")
                .disabled(library?.canCreate != true)
            Button("Add Link…") { library?.addLink() }
                .keyboardShortcut("l")
                .disabled(library?.canCreate != true)
            Button("New Project…") { library?.newProject?() }
                .disabled(library?.newProject == nil)
            Divider()
            Button("Import Audio…") { library?.importAudio() }
                .disabled(library?.canCreate != true)
            Button("Import Plaud…") { library?.importPlaud() }
                .disabled(library?.canCreate != true || library?.plaudSignedIn != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Search") { library?.search() }
                .keyboardShortcut("f")
                .disabled(library == nil)
            if let filter {
                Picker("Filter", selection: filter) {
                    ForEach(HomeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } else {
                Menu("Filter") {}.disabled(true)
            }
        }
        CommandMenu("Note") {
            Button(note?.isPinned == true ? "Unpin" : "Pin") { note?.togglePin() }
                .disabled(note == nil || note?.isDeleted == true)
            Divider()
            Button(note?.hasSummary == true ? "Summarize Again" : "Summarize") { note?.summarize() }
                .disabled(note?.canSummarize != true || note?.isDeleted == true)
            Button(note?.hasSummary == true ? "Edit Summary" : "Write Summary") { note?.editSummary() }
                .disabled(note?.canEditSummary != true || note?.isDeleted == true)
            Divider()
            Button("Transcribe Again") { note?.transcribeAgain() }
                .disabled(note?.canTranscribe != true || note?.isDeleted == true)
            Button("Copy Transcript") { note?.copyTranscript() }
                .disabled(note?.hasTranscript != true)
            Divider()
            if note?.isDeleted == true {
                Button("Recover") { note?.recover() }
            } else {
                Button("Delete") { note?.delete() }
                    .disabled(note == nil)
            }
        }
    }
}

/// Tells about a newer version once it is found; "Skip" keeps quiet until the version after it.
private struct UpdateAlert: ViewModifier {
    let update: AppUpdate
    /// Closed for now by Download; the version stays on offer in the menu, and only "Skip" skips it.
    @State private var closedTag: String?

    func body(content: Content) -> some View {
        content.alert(
            "Porridge \(update.available?.version ?? "") Available",
            isPresented: .init(
                get: { update.available.map { $0.tag != closedTag } ?? false },
                set: { if !$0 { closedTag = update.available?.tag } }
            )
        ) {
            Button("Download") { update.download() }
            Button("Skip This Version", role: .cancel) { update.skip() }
        } message: {
            Text(update.available?.notes.isEmpty == false
                ? update.available!.notes
                : "You have \(AppUpdate.currentVersion). The download is a zip with the new app; replace the old one in Applications.")
        }
    }
}

extension View {
    func updateAlert(_ update: AppUpdate) -> some View {
        modifier(UpdateAlert(update: update))
    }
}

private struct MenuBarContent: View {
    let dictation: DictationController
    let update: AppUpdate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if DictationSettings.enabled {
            if dictation.shortcutNeedsAccessibility {
                Button("Allow Accessibility for the Shortcut…") { TextInserter.requestAccess() }
            } else {
                Text(dictation.shortcutUnavailable
                    ? "Shortcut is used by another app"
                    : "Dictate: \(DictationSettings.shortcutDescription)")
            }
        }
        Button(dictation.isRecording ? "Stop Dictation" : "Start Dictation") {
            dictation.toggleFromMenu()
        }
        Divider()
        Button("Open Porridge") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        if let release = update.available {
            Divider()
            Button("Download Porridge \(release.version)…") { update.download() }
        }
        Divider()
        Button("Quit Porridge") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

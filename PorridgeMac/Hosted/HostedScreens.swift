import AppKit
import SwiftUI

// Screens that are not ported to AppKit yet, embedded until their stage is done. This file goes away at the end.

/// The SwiftUI environment the shared views expect.
@MainActor
func hosted<Content: View>(_ view: Content) -> some View {
    view
        .environment(Library.shared.processing)
        .environment(ModelManager.shared)
        .modelContainer(Library.shared.container)
}

/// Presents a SwiftUI screen as a sheet of a window; `dismiss` in it closes the sheet.
@MainActor
enum HostedSheet {
    @discardableResult
    static func present<Content: View>(_ view: Content, in window: NSWindow?, size: NSSize = NSSize(width: 520, height: 560)) -> NSViewController {
        let controller = NSHostingController(rootView: AnyView(hosted(view.frame(minWidth: size.width, minHeight: size.height))))
        controller.sizingOptions = [.preferredContentSize]
        if let window, let content = window.contentViewController {
            content.presentAsSheet(controller)
        } else {
            let panel = NSWindow(contentViewController: controller)
            panel.makeKeyAndOrderFront(nil)
        }
        return controller
    }
}

final class ChatViewController: NSViewController {
    private let state: WindowState
    private var token: UUID?
    private var observing: Observing?

    init(state: WindowState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSHostingView(rootView: AnyView(EmptyView()))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        token = Library.shared.observe { [weak self] in self?.render() }
        observing = Observing { [weak self] in
            guard let self else { return }
            _ = (self.state.chatID, self.state.chatScope)
            self.render()
        }
    }

    private func render() {
        let library = Library.shared
        let state = state
        let thread = library.threads.first { $0.id == state.chatID }
        (view as? NSHostingView<AnyView>)?.rootView = AnyView(hosted(
            ChatView(
                thread: thread, notes: library.notes, projects: library.projects,
                scope: Binding(get: { state.chatScope }, set: { state.chatScope = $0 }),
                onOpen: { id in
                    if let note = Library.shared.note(id) { state.reveal(note) }
                },
                onCreate: { thread in state.chatID = thread.id }
            )
        ))
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: hosted(SettingsView(isEmbedded: true).frame(width: 640, height: 760))))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
enum Onboarding {
    static func showIfNeeded(in window: NSWindow?) {
        guard !UserDefaults.standard.bool(forKey: AppSettings.onboardingDoneKey) else { return }
        final class Box { var controller: NSViewController? }
        let box = Box()
        box.controller = HostedSheet.present(OnboardingView {
            UserDefaults.standard.set(true, forKey: AppSettings.onboardingDoneKey)
            box.controller?.dismiss(nil)
        }, in: window, size: NSSize(width: 520, height: 640))
    }
}

@MainActor
enum NoteSheets {
    static func summaryOptions(for note: Note, in controller: NSViewController) {
        let processing = Library.shared.processing
        HostedSheet.present(SummaryOptionsSheet(
            replacesSummary: note.summary != nil,
            showsTemplates: !note.segments.isEmpty,
            material: !note.segments.isEmpty ? "transcript" : note.isLink ? "page" : "note"
        ) { template, model in
            guard !processing.summarizing.contains(note.id) else { return }
            processing.enqueue(.summary(note.id, template, model))
        }, in: controller.view.window)
    }

    static func enhanceOptions(for note: Note, in controller: NSViewController) {
        let processing = Library.shared.processing
        HostedSheet.present(SummaryOptionsSheet(replacesSummary: false, showsTemplates: false, material: "note", enhances: true) { _, model in
            guard !processing.enhancing.contains(note.id) else { return }
            processing.enqueue(.enhance(note.id, model))
        }, in: controller.view.window)
    }

    static func editSummary(of note: Note, in controller: NSViewController) {
        if note.summary == nil { note.summary = "" }
        HostedSheet.present(SummaryEditorSheet(text: Binding(get: { note.summary ?? "" }, set: { note.summary = $0 })), in: controller.view.window)
    }

    static func merge(_ note: Note, in controller: NSViewController) {
        HostedSheet.present(MergeNotesSheet(base: note) {}, in: controller.view.window)
    }

    static func export(_ note: Note, in controller: NSViewController) {
        HostedSheet.present(MeetingExportSheet(note: note), in: controller.view.window)
    }

    static func continueRecording(_ note: Note, in controller: NSViewController) {
        Capture.continueRecording(note)
    }
}


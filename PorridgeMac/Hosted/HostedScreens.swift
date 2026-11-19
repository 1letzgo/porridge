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
        HostedSheet.present(RecordingView(title: note.title, continues: note.id) { result, _, _, written in
            note.addRecordedPart(result.fileName, written: written)
            Library.shared.save()
            Library.shared.processing.enqueue(.note(note.id))
        }, in: controller.view.window, size: NSSize(width: 560, height: 640))
    }
}

@MainActor
enum Capture {
    static func recordMeeting(in controller: MainWindowController) {
        let state = controller.state
        let window = controller.window
        HostedSheet.present(RecordMeetingSheet(
            onPick: { appointment in startRecording(title: appointment.title, state: state, window: window) },
            onNew: { startRecording(title: nil, state: state, window: window) }
        ), in: window)
    }

    private static func startRecording(title: String?, state: WindowState, window: NSWindow?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            HostedSheet.present(RecordingView(title: title) { result, names, liveText, written in
                let note = Note()
                note.source = .meeting
                note.title = title ?? Note.defaultMeetingTitle(for: note.createdAt)
                note.titleIsCustom = title != nil
                note.statusRaw = ProcessingStatus.recorded.rawValue
                note.audioFileName = result.fileName
                note.duration = result.duration
                note.channelCount = result.channelCount
                note.inputName = result.inputName
                note.text = RecordingNote.markdown(written)
                if result.isSplitStereo {
                    note.speakerMode = .channels
                    note.speakers = [
                        Speaker(id: SpeakerAssigner.leftChannelID, name: names[0], colorIndex: 0),
                        Speaker(id: SpeakerAssigner.rightChannelID, name: names[1], colorIndex: 1),
                    ]
                }
                if !liveText.isEmpty {
                    note.segments = [TranscriptSegment(speakerId: nil, start: 0, end: result.duration, text: liveText)]
                }
                if let project = state.projectForNew { note.projectIDs = [project] }
                let library = Library.shared
                library.context.insert(note)
                library.save()
                state.open(note.id)
                library.processing.enqueue(.transcript(note.id))
            }, in: window, size: NSSize(width: 560, height: 640))
        }
    }

    static func importPlaud(in controller: MainWindowController) {
        let state = controller.state
        HostedSheet.present(PlaudImportSheet { audio in
            let library = Library.shared
            PlaudImporter.addNote(audio, projectID: state.projectForNew, context: library.context, processing: library.processing)
        }, in: controller.window)
    }
}

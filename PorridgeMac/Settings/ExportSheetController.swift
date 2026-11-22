import AppKit

/// Exporting on the Mac: everything (Settings › General) or one bowl (its menu) is written as a folder where the user
/// chooses, while a sheet shows the progress and can cancel it. Done, the folder shows in the Finder.
@MainActor
final class ExportSheetController: NSViewController {
    /// One export at a time.
    private static var current: ExportSheetController?

    /// Asks where the folder goes, then exports into it.
    static func export(_ scope: FullExport.Scope, title: String, in window: NSWindow?) {
        if let current {
            current.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Choose where the export folder goes.")
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let directory = panel.url else { return }
            let controller = ExportSheetController(run: ExportRun(scope: scope, title: title))
            current = controller
            if let window {
                // The open panel's sheet has to be gone before the next one comes.
                DispatchQueue.main.async {
                    window.contentViewController?.presentAsSheet(controller)
                    controller.start(into: directory)
                }
            } else {
                let host = NSWindow(contentViewController: controller)
                host.title = title
                host.makeKeyAndOrderFront(nil)
                controller.start(into: directory)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    private let run: ExportRun
    private let status = NSTextField.label("", color: .secondaryLabelColor, lines: 3)
    private let progress = NSProgressIndicator()
    private lazy var cancelButton = SettingsSheet.cancelButton { [weak self] in self?.cancelOrClose() }
    private lazy var revealButton = NSButton.push(String(localized: "Show in Finder")) { [weak self] in self?.reveal() }
    private lazy var doneButton = SettingsSheet.defaultButton(String(localized: "Done")) { [weak self] in self?.close() }
    private var directory: URL?

    init(run: ExportRun) {
        self.run = run
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.translatesAutoresizingMaskIntoConstraints = false
        let title = SettingsSheet.title(run.title)
        title.lineBreakMode = .byTruncatingTail
        let body = NSStackView.vertical([title, progress, status], spacing: 12)
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 4, right: 20)
        revealButton.isHidden = true
        doneButton.isHidden = true
        let page = NSStackView.vertical([body, SettingsSheet.footer(right: [cancelButton, revealButton, doneButton])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: 420),
            progress.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            status.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
        ])
        view = page
        render()
    }

    private func start(into directory: URL) {
        self.directory = directory
        run.onChange = { [weak self] in self?.render() }
        // A folder chosen in the open panel can be written in the sandbox for as long as the app runs.
        run.start(context: Library.shared.context, into: directory, zip: false)
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        status.stringValue = run.statusText
        switch run.state {
        case .running, .packing:
            progress.doubleValue = run.fraction
            progress.isHidden = false
            cancelButton.isHidden = false
            revealButton.isHidden = true
            doneButton.isHidden = true
        case .finished:
            progress.doubleValue = 1
            cancelButton.isHidden = true
            revealButton.isHidden = false
            doneButton.isHidden = false
        case .failed, .cancelled:
            progress.isHidden = true
            cancelButton.isHidden = true
            revealButton.isHidden = true
            doneButton.isHidden = false
        }
    }

    private func cancelOrClose() {
        if run.isRunning { run.cancel() } else { close() }
    }

    private func reveal() {
        if case .finished(let url) = run.state { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        close()
    }

    private func close() {
        run.cancel()
        run.onChange = nil
        Self.current = nil
        if presentingViewController != nil { dismiss(nil) } else { view.window?.close() }
    }
}

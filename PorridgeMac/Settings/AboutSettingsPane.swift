import AppKit

/// About: the version, the update check (GitHub builds only) and the acknowledgements.
final class AboutSettingsPane: SettingsPane {
    private let update = AppUpdate.shared
    private lazy var updateButton = NSButton.push("Check Now") { [weak self] in
        guard let self else { return }
        if self.update.available != nil {
            self.update.download()
        } else {
            Task { await self.update.check(manual: true) }
        }
    }
    private var resultLabel = NSTextField()
    private var resultRow: NSGridRow?

    override func build() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        form.row("Version", NSTextField.label(version, color: .secondaryLabelColor))
        if AppUpdate.isEnabled {
            // Newer versions come as GitHub releases; the app looks for them by itself and on request.
            form.row("Updates", updateButton)
            let note = form.note()
            resultRow = note.row
            resultLabel = note.label
        }
        form.separator()
        form.row("Acknowledgements", NSButton.push("Show…") { [weak self] in
            self?.presentSheet(AcknowledgementsSheetController())
        })
        form.note("Speech recognition: FluidAudio · NVIDIA Parakeet (CC-BY-4.0) · pyannote")
    }

    override func render() {
        guard AppUpdate.isEnabled else { return }
        if let release = update.available {
            updateButton.title = "Download \(release.version)"
            updateButton.isEnabled = true
        } else {
            updateButton.title = update.checking ? "Checking…" : "Check Now"
            updateButton.isEnabled = !update.checking
        }
        let result = update.lastResult
        resultLabel.stringValue = result ?? ""
        if resultRow?.isHidden != (result == nil) {
            resultRow?.isHidden = result == nil
            contentChanged()
        }
    }
}

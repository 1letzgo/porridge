import AppKit

/// Whether the notes sync through iCloud between the user's Apple devices. Switching takes effect at the next launch.
final class SyncSettingsPane: SettingsPane {
    private lazy var modePopUp = SettingsPopUp { [weak self] index in
        let modes = SyncMode.allCases
        guard index >= 0, index < modes.count else { return }
        UserDefaults.standard.set(modes[index].rawValue, forKey: SyncMode.key)
        self?.render()
    }
    private var restartLabel = NSTextField()
    private let iCloudLabel = NSTextField.label()
    private let iCloudImage = NSImageView()

    private var restartRow: NSGridRow?
    private var iCloudRow: NSGridRow?
    private var visibility: [Bool] = []

    override func build() {
        form.row("Sync With", modePopUp)
        let restart = form.note()
        restartRow = restart.row
        restartLabel = restart.label

        iCloudImage.translatesAutoresizingMaskIntoConstraints = false
        iCloudRow = form.row("iCloud", NSStackView.horizontal([iCloudImage, iCloudLabel], spacing: 6))
    }

    override func render() {
        let mode = SyncMode.chosen
        modePopUp.set(SyncMode.allCases.map(\.label), selected: SyncMode.allCases.firstIndex(of: mode))
        let needsRestart = mode != SyncMode.active
        restartLabel.stringValue = mode == .iCloud ? "Restart Porridge to sync with iCloud." : "Restart Porridge to stop syncing."

        let available = FileManager.default.ubiquityIdentityToken != nil
        iCloudLabel.stringValue = available ? "Signed in to iCloud" : "Not signed in to iCloud"
        iCloudImage.image = .symbol(available ? "checkmark.icloud.fill" : "xmark.icloud", size: 14)
        iCloudImage.contentTintColor = available ? .controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.6)

        let showsICloud = mode == .iCloud
        let now = [needsRestart, showsICloud]
        if now != visibility {
            visibility = now
            restartRow?.isHidden = !needsRestart
            iCloudRow?.isHidden = !showsICloud
            contentChanged()
        }
    }
}

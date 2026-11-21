import AppKit

/// General: who the user is (the summaries name them), the Plaud account, iCloud sync and the version with the
/// acknowledgements. Switching sync takes effect at the next launch; updates come through TestFlight.
final class GeneralSettingsPane: SettingsPane {
    private lazy var nameField = SettingsTextField(placeholder: "Your Name") { name in
        UserDefaults.standard.set(name, forKey: AppSettings.myNameKey)
    }
    private let plaudStatus = NSTextField.label()
    private lazy var plaudButton = NSButton.push("Sign In…") { [weak self] in self?.plaudTapped() }

    private lazy var iCloudSync = SettingsCheckbox("iCloud Sync") { [weak self] on in
        UserDefaults.standard.set((on ? SyncMode.iCloud : SyncMode.off).rawValue, forKey: SyncMode.key)
        self?.render()
    }
    private var restartLabel = NSTextField()
    private let iCloudLabel = NSTextField.label()
    private let iCloudImage = NSImageView()
    private var restartRow: NSGridRow?
    private var iCloudRow: NSGridRow?
    private var syncVisibility: [Bool] = []

    override func build() {
        form.row("Your Name", nameField)
        form.note("Summaries call you by this name.")
        form.separator()
        form.row("Plaud", NSStackView.horizontal([plaudStatus, plaudButton], spacing: 12))
        form.separator()

        form.row("", iCloudSync)
        let restart = form.note()
        restartRow = restart.row
        restartLabel = restart.label
        iCloudImage.translatesAutoresizingMaskIntoConstraints = false
        iCloudRow = form.row("iCloud", NSStackView.horizontal([iCloudImage, iCloudLabel], spacing: 6))
        form.separator()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        form.row("Version", NSTextField.label(version, color: .secondaryLabelColor))
        form.row("Acknowledgements", NSButton.push("Show…") { [weak self] in
            self?.presentSheet(AcknowledgementsSheetController())
        })
        form.note("Speech recognition: FluidAudio · NVIDIA Parakeet (CC-BY-4.0) · pyannote")
    }

    override func render() {
        nameField.show(UserDefaults.standard.string(forKey: AppSettings.myNameKey) ?? "")
        let signedIn = PlaudAccount.isSignedIn
        plaudStatus.stringValue = signedIn ? "Signed In" : "Not Signed In"
        plaudButton.title = signedIn ? "Sign Out" : "Sign In…"
        plaudButton.hasDestructiveAction = signedIn
        renderSync()
    }

    private func renderSync() {
        let mode = SyncMode.chosen
        iCloudSync.isOn = mode == .iCloud
        let needsRestart = mode != SyncMode.active
        restartLabel.stringValue = mode == .iCloud ? "Restart Porridge to sync with iCloud." : "Restart Porridge to stop syncing."

        let available = FileManager.default.ubiquityIdentityToken != nil
        iCloudLabel.stringValue = available ? "Signed in to iCloud" : "Not signed in to iCloud"
        iCloudImage.image = .symbol(available ? "checkmark.icloud.fill" : "xmark.icloud", size: 14)
        iCloudImage.contentTintColor = available ? .controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.6)

        let showsICloud = mode == .iCloud
        let now = [needsRestart, showsICloud]
        if now != syncVisibility {
            syncVisibility = now
            restartRow?.isHidden = !needsRestart
            iCloudRow?.isHidden = !showsICloud
            contentChanged()
        }
    }

    private func plaudTapped() {
        if PlaudAccount.isSignedIn {
            PlaudAccount.clear()
            Task { await PlaudLogin.clearSession() }
            plaudChanged()
        } else {
            PlaudLogin.present(in: view.window) { [weak self] token, refreshToken in
                PlaudImporter().signIn(token: token, refreshToken: refreshToken)
                self?.plaudChanged()
            }
        }
    }

    private func plaudChanged() {
        render()
        NotificationCenter.default.post(name: .plaudAccountChanged, object: nil)
    }
}

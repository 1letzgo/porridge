import AppKit

/// Where the notes go: iCloud between Apple devices, a Nextcloud for every platform, or nowhere. Switching takes
/// effect at the next launch.
final class SyncSettingsPane: SettingsPane {
    private let sync = NextcloudSync.shared
    private var login: Task<Void, Never>?
    private var loginError: String?

    private lazy var modePopUp = SettingsPopUp { [weak self] index in
        let modes = SyncMode.allCases
        guard index >= 0, index < modes.count else { return }
        UserDefaults.standard.set(modes[index].rawValue, forKey: SyncMode.key)
        self?.render()
    }
    private var restartLabel = NSTextField()
    private let iCloudLabel = NSTextField.label()
    private let iCloudImage = NSImageView()
    private let accountLabel = NSTextField.label(color: .secondaryLabelColor)
    private let statusLabel = SettingsForm.footnote("", width: SettingsMetrics.controlWidth)
    private lazy var wifiOnly = SettingsCheckbox("Upload Recordings on Wi-Fi Only") { [weak self] on in
        UserDefaults.standard.set(on, forKey: AppSettings.recordingsWiFiOnlyKey)
        self?.sync.wifiOnlyChanged()
    }
    private lazy var syncNowButton = NSButton.push("Sync Now") { Task { await NextcloudSync.shared.sync() } }
    private lazy var disconnectButton = NSButton.push("Disconnect…") { [weak self] in self?.confirmDisconnect() }
    private lazy var serverField = SettingsTextField(placeholder: "Server, e.g. cloud.example.com", width: 280) { [weak self] _ in
        self?.render()
    }
    private lazy var connectButton = NSButton.push("Connect") { [weak self] in self?.connect() }
    private let spinner = NSProgressIndicator()
    private let waitingLabel = NSTextField.label("Confirm the login in your browser.", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private lazy var cancelLoginButton = NSButton.push("Cancel") { [weak self] in
        self?.login?.cancel()
        self?.login = nil
        self?.render()
    }
    private var errorLabel = NSTextField()

    private var restartRow: NSGridRow?
    private var iCloudRows: [NSGridRow] = []
    private var accountRows: [NSGridRow] = []
    private var loginRows: [NSGridRow] = []
    private var errorRow: NSGridRow?
    private var visibility: [Bool] = []

    override func build() {
        form.row("Sync With", modePopUp)
        let restart = form.note()
        restartRow = restart.row
        restartLabel = restart.label

        iCloudImage.translatesAutoresizingMaskIntoConstraints = false
        iCloudRows.append(form.row("iCloud", NSStackView.horizontal([iCloudImage, iCloudLabel], spacing: 6)))

        accountRows.append(form.row("Account", accountLabel))
        accountRows.append(form.row("Status", statusLabel))
        accountRows.append(form.row("", wifiOnly))
        disconnectButton.hasDestructiveAction = true
        accountRows.append(form.row("", NSStackView.horizontal([syncNowButton, disconnectButton], spacing: 10)))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        loginRows.append(form.row("Server", serverField))
        loginRows.append(form.row("", NSStackView.horizontal([connectButton, spinner, waitingLabel, cancelLoginButton], spacing: 8)))
        let error = form.note(color: .brandDangerText)
        errorRow = error.row
        errorLabel = error.label
    }

    override func render() {
        let mode = SyncMode.chosen
        modePopUp.set(SyncMode.allCases.map(\.label), selected: SyncMode.allCases.firstIndex(of: mode))
        let needsRestart = mode != SyncMode.active
        restartLabel.stringValue = "Restart Porridge to switch to \(mode.label)."

        let available = FileManager.default.ubiquityIdentityToken != nil
        iCloudLabel.stringValue = available ? "Signed in to iCloud" : "Not signed in to iCloud"
        iCloudImage.image = .symbol(available ? "checkmark.icloud.fill" : "xmark.icloud", size: 14)
        iCloudImage.contentTintColor = available ? .controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.6)

        let account = sync.account
        accountLabel.stringValue = account?.label ?? ""
        statusLabel.stringValue = status
        wifiOnly.isOn = UserDefaults.standard.bool(forKey: AppSettings.recordingsWiFiOnlyKey)
        syncNowButton.title = sync.isSyncing ? "Syncing…" : "Sync Now"
        syncNowButton.isEnabled = !sync.isSyncing && SyncMode.active == .nextcloud

        let loggingIn = login != nil
        connectButton.isHidden = loggingIn
        connectButton.isEnabled = NextcloudLogin.normalize(serverField.stringValue) != nil
        waitingLabel.isHidden = !loggingIn
        cancelLoginButton.isHidden = !loggingIn
        if loggingIn { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        errorLabel.stringValue = loginError ?? ""

        let showsICloud = mode == .iCloud
        let showsAccount = mode == .nextcloud && account != nil
        let showsLogin = mode == .nextcloud && account == nil
        let showsError = showsLogin && loginError != nil
        let now = [needsRestart, showsICloud, showsAccount, showsLogin, showsError]
        if now != visibility {
            visibility = now
            restartRow?.isHidden = !needsRestart
            iCloudRows.forEach { $0.isHidden = !showsICloud }
            accountRows.forEach { $0.isHidden = !showsAccount }
            loginRows.forEach { $0.isHidden = !showsLogin }
            errorRow?.isHidden = !showsError
            contentChanged()
        }
    }

    private var status: String {
        if sync.isSyncing { return "Syncing…" }
        if SyncMode.active != .nextcloud { return "After restart" }
        if let error = sync.lastError { return error }
        guard let last = sync.lastSync else { return "Not synced yet" }
        return "Synced \(last.formatted(.relative(presentation: .named)))"
    }

    private func connect() {
        guard let url = NextcloudLogin.normalize(serverField.stringValue) else { return }
        loginError = nil
        login = Task { [weak self] in
            defer {
                self?.login = nil
                self?.render()
            }
            do {
                let pending = try await NextcloudLogin.start(server: url)
                NSWorkspace.shared.open(pending.loginURL)
                let account = try await NextcloudLogin.finish(pending)
                NextcloudSync.shared.connect(account)
            } catch is CancellationError {
            } catch {
                self?.loginError = error.localizedDescription
            }
        }
        render()
    }

    private func confirmDisconnect() {
        Alerts.confirm(
            "Disconnect from Nextcloud?",
            message: "Your notes stay on this device and on the server. They are no longer kept in sync.",
            action: "Disconnect", in: view.window
        ) { [weak self] in
            NextcloudSync.shared.disconnect()
            self?.render()
        }
    }
}

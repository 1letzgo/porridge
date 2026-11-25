import AppKit

/// General: who the user is (the summaries name them), iCloud sync, the Plaud account, Sort Bowls By, note
/// templates, hints, export and the version with the acknowledgements. Switching sync takes effect at the next launch; updates come through TestFlight.
final class GeneralSettingsPane: SettingsPane {
    private lazy var nameField = SettingsTextField(placeholder: "Your Name") { name in
        UserDefaults.standard.set(name, forKey: AppSettings.myNameKey)
    }
    private let plaudStatus = NSTextField.label()
    private lazy var plaudButton = NSButton.push("Sign In…") { [weak self] in self?.plaudTapped() }

    private lazy var iCloudSync = SettingsCheckbox("iCloud Sync") { [weak self] on in
        self?.syncTapped(on ? .iCloud : .off)
    }
    /// Sort Bowls By: the order of the sidebar's bowls and the Bowls place (the iPhone has the same setting).
    private lazy var bowlOrder = SettingsPopUp { index in
        guard HomeList.BowlOrder.allCases.indices.contains(index) else { return }
        UserDefaults.standard.set(HomeList.BowlOrder.allCases[index].rawValue, forKey: HomeList.bowlOrderKey)
        Library.shared.setNeedsReload()
    }
    private lazy var dailyHint = SettingsCheckbox("Daily Hint in Today") { on in
        UserDefaults.standard.set(on, forKey: DailyHint.enabledKey)
        DailyHints.shared.refresh(notes: Library.shared.notes)
    }

    override func build() {
        // The order of the iPhone's General: who you are, sync, Plaud, how bowls are sorted, note templates, hints,
        // export, the version.
        form.row("Your Name", nameField)
        form.note("Summaries call you by this name.")
        form.separator()

        form.row("", iCloudSync)
        form.separator()

        form.row("Plaud", NSStackView.horizontal([plaudStatus, plaudButton], spacing: 12))
        form.separator()

        form.row("Sort Bowls By", bowlOrder)
        form.note("The order of the bowls in the sidebar and the Bowls place. Pinned bowls are always shown first.")
        form.separator()

        form.row("Note Templates", NSButton.push("Edit Note Templates…") { [weak self] in
            self?.presentSheet(NoteTemplatesSheetController())
        })
        form.note("Start notes and to-dos from a template, or insert one into a note.")
        form.separator()

        form.row("Hints", dailyHint)
        form.note("At most one a day, across your devices. Hints you leave alone go quiet for a while.")
        form.separator()

        form.row("Export", NSButton.push("Export Everything…") { [weak self] in
            ExportSheetController.export(.everything, title: String(localized: "Export Everything"), in: self?.view.window)
        })
        form.note("A Markdown file for each entry with its attachments and recordings next to it, and all data as JSON, in a folder.")
        form.separator()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        form.row("Version", NSTextField.label(version, color: .secondaryLabelColor))
        form.row("Acknowledgements", NSButton.push("Show…") { [weak self] in
            self?.presentSheet(AcknowledgementsSheetController())
        })
    }

    override func render() {
        nameField.show(UserDefaults.standard.string(forKey: AppSettings.myNameKey) ?? "")
        let signedIn = PlaudAccount.isSignedIn
        plaudStatus.stringValue = signedIn ? "Signed In" : "Not Signed In"
        plaudButton.title = signedIn ? "Sign Out" : "Sign In…"
        plaudButton.hasDestructiveAction = signedIn
        iCloudSync.isOn = SyncMode.chosen == .iCloud
        dailyHint.isOn = DailyHint.isEnabled
        bowlOrder.set(HomeList.BowlOrder.allCases.map(\.title), selected: HomeList.BowlOrder.allCases.firstIndex(of: HomeList.bowlOrder))
    }

    /// Asks before switching sync; the checkbox shows the stored mode until the user confirms.
    private func syncTapped(_ target: SyncMode) {
        render()
        Alerts.confirm(
            target.confirmTitle, message: target.confirmMessage, action: target.confirmAction,
            isDestructive: target == .off, in: view.window
        ) { [weak self] in
            UserDefaults.standard.set(target.rawValue, forKey: SyncMode.key)
            self?.render()
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

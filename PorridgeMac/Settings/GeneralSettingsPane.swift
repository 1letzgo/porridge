import AppKit

/// General: who the user is (the summaries name them) and the Plaud account.
final class GeneralSettingsPane: SettingsPane {
    private lazy var nameField = SettingsTextField(placeholder: "Your Name") { name in
        UserDefaults.standard.set(name, forKey: AppSettings.myNameKey)
    }
    private let plaudStatus = NSTextField.label()
    private lazy var plaudButton = NSButton.push("Sign In…") { [weak self] in self?.plaudTapped() }

    override func build() {
        form.row("Your Name", nameField)
        form.note("Summaries call you by this name.")
        form.separator()
        form.row("Plaud", NSStackView.horizontal([plaudStatus, plaudButton], spacing: 12))
    }

    override func render() {
        nameField.show(UserDefaults.standard.string(forKey: AppSettings.myNameKey) ?? "")
        let signedIn = PlaudAccount.isSignedIn
        plaudStatus.stringValue = signedIn ? "Signed In" : "Not Signed In"
        plaudButton.title = signedIn ? "Sign Out" : "Sign In…"
        plaudButton.hasDestructiveAction = signedIn
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

import AppKit

/// Summary: whether incoming entries are summarized as they come in, and the custom templates.
final class SummarySettingsPane: SettingsPane {
    private lazy var summarizeIncoming = SettingsCheckbox("Summarize Incoming Entries") { on in
        UserDefaults.standard.set(on, forKey: AppSettings.summarizeIncomingKey)
        if on { Library.shared.processing.summarizeIncoming() }
    }

    override func build() {
        form.row("", summarizeIncoming)
        form.row("Templates", NSButton.push("Edit Custom Templates…") { [weak self] in
            self?.presentSheet(TemplatesSheetController())
        })
    }

    override func render() {
        summarizeIncoming.isOn = AppSettings.summarizeIncoming
    }
}

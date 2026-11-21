import AppKit

/// About: the version and the acknowledgements. Updates come through TestFlight.
final class AboutSettingsPane: SettingsPane {
    override func build() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        form.row("Version", NSTextField.label(version, color: .secondaryLabelColor))
        form.separator()
        form.row("Acknowledgements", NSButton.push("Show…") { [weak self] in
            self?.presentSheet(AcknowledgementsSheetController())
        })
        form.note("Speech recognition: FluidAudio · NVIDIA Parakeet (CC-BY-4.0) · pyannote")
    }
}

import AppKit
import SwiftData

/// The voices Porridge has learned: which one is yours, what they are called, and forgetting one. The Mac form
/// of `VoicesView`.
final class VoicesSheetController: NSViewController {
    private var list = NSStackView()
    private var libraryToken: UUID?
    private static let width: CGFloat = 520

    override func loadView() {
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 12)
        list = stack
        let done = SettingsSheet.defaultButton("Done") { [weak self] in self?.dismiss(nil) }
        let header = NSStackView.horizontal([SettingsSheet.title("Known Voices")])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        let page = NSStackView.vertical([header, scroll, SettingsSheet.footer(right: [done])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: Self.width),
            page.heightAnchor.constraint(equalToConstant: 520),
        ])
        view = page
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        libraryToken = Library.shared.observe { [weak self] in self?.render() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        Library.shared.stopObserving(libraryToken)
        libraryToken = nil
    }

    private var context: ModelContext { Library.shared.context }

    /// By name, the user's own voice on top.
    private var voices: [VoiceProfile] {
        let myVoice = UserDefaults.standard.string(forKey: AppSettings.myVoiceKey) ?? ""
        let all = (try? context.fetch(FetchDescriptor<VoiceProfile>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return all.sorted { ($0.id.uuidString == myVoice ? 0 : 1) < ($1.id.uuidString == myVoice ? 0 : 1) }
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = Self.width - 40
        let voices = voices
        for voice in voices {
            list.addArrangedSubview(row(voice, width: width))
            list.addArrangedSubview(SettingsSheet.hairline(width: width))
        }
        // Without voices the page would otherwise be empty, with nothing to say how one gets there.
        if voices.isEmpty {
            list.addArrangedSubview(SettingsForm.footnote("No voices yet. Naming a speaker in a meeting teaches Porridge the voice.", width: width))
        }
    }

    private func row(_ voice: VoiceProfile, width: CGFloat) -> NSView {
        let isMe = voice.id.uuidString == UserDefaults.standard.string(forKey: AppSettings.myVoiceKey)
        let name = NSTextField.label(isMe ? "\(voice.name) (me)" : voice.name)
        let detail = NSTextField.label("\(voice.seconds.clockString) of speech", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        let text = NSStackView.vertical([name, detail], spacing: 2)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let me = NSButton.symbolButton(
            isMe ? "person.crop.circle.fill" : "person.crop.circle", label: isMe ? "Not Me" : "This Is Me",
            tint: isMe ? .brandTaskText : .controlAccentColor
        ) { [weak self] in
            AppSettings.setMyVoice(isMe ? nil : voice)
            self?.render()
        }
        let rename = NSButton.symbolButton("pencil", label: "Rename") { [weak self] in self?.rename(voice) }
        let forget = NSButton.symbolButton("trash", label: "Forget Voice", tint: .brandDangerText) { [weak self] in self?.forget(voice) }
        let row = NSStackView.horizontal([text, me, rename, forget], spacing: 12)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func rename(_ voice: VoiceProfile) {
        Alerts.ask("Rename Voice", placeholder: "Name", value: voice.name, action: "Save", in: view.window) { [weak self] text in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            VoiceProfiles.rename(voice, to: name, context: self.context)
            self.render()
        }
    }

    private func forget(_ voice: VoiceProfile) {
        Alerts.confirm("Forget Voice?", message: "Names already given in meetings stay.", action: "Forget Voice", in: view.window) { [weak self] in
            guard let self else { return }
            VoiceProfiles.delete(voice, context: self.context)
            self.render()
        }
    }
}

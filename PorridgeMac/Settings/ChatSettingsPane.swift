import AppKit

/// Chat: the model the chat answers with ("Same as Default" or one of the models of the list).
final class ChatSettingsPane: SettingsPane {
    /// "Same as Default", then the models of the list: the chat may answer with another model than the summaries.
    private lazy var chatPopUp = SettingsPopUp { [weak self] index in
        let available = SummaryModel.available
        SummaryModel.chatChoice = index > 0 && index <= available.count ? available[index - 1] : nil
        self?.render()
    }
    private let noneLabel = NSTextField.label("None added", color: .secondaryLabelColor)
    private let chatHint = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private var popUpRow: NSGridRow?
    private var noneRow: NSGridRow?
    private var hintRow: NSGridRow?

    override func build() {
        popUpRow = form.row("Chat Model", chatPopUp)
        noneRow = form.row("Chat Model", noneLabel)
        hintRow = form.row("", chatHint)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        SummaryModel.repairCurrent()
        render()
    }

    override func render() {
        let available = SummaryModel.available
        let hasModels = !available.isEmpty
        chatPopUp.set(["Same as Default"] + available.map(\.name), selected: SummaryModel.chatChoice.flatMap { available.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        let hint = SummaryModel.chat.sendsHint("question and excerpts of your notes") ?? ""
        let showsHint = hasModels && !hint.isEmpty
        chatHint.stringValue = hint
        if popUpRow?.isHidden != !hasModels || noneRow?.isHidden != hasModels || hintRow?.isHidden != !showsHint {
            popUpRow?.isHidden = !hasModels
            noneRow?.isHidden = hasModels
            hintRow?.isHidden = !showsHint
            contentChanged()
        }
    }
}

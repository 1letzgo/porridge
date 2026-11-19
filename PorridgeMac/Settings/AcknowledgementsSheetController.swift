import AppKit

/// The third-party packages and models the app uses (`Acknowledgements.bundled`): name, version, license, and the
/// license text, which opens with the disclosure button. The Mac form of `AcknowledgementsView`.
final class AcknowledgementsSheetController: NSViewController {
    private let list = Acknowledgements.bundled
    private static let width: CGFloat = 600

    override func loadView() {
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 14)
        let width = Self.width - 40
        stack.addArrangedSubview(SettingsForm.footnote(
            "Porridge is built with these open source packages and models. Thank you to everyone who made them.", width: width
        ))
        for section in list.sections {
            stack.setCustomSpacing(28, after: stack.arrangedSubviews.last ?? stack)
            stack.addArrangedSubview(SettingsSheet.sectionHead(section.title, width: width))
            for (index, entry) in section.entries.enumerated() {
                if index > 0 { stack.addArrangedSubview(SettingsSheet.hairline(width: width)) }
                stack.addArrangedSubview(EntryView(entry: entry, license: list.licenses[entry.text] ?? "", width: width))
            }
        }
        let done = SettingsSheet.defaultButton("Done") { [weak self] in self?.dismiss(nil) }
        let header = NSStackView.horizontal([SettingsSheet.title("Acknowledgements")])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        let page = NSStackView.vertical([header, scroll, SettingsSheet.footer(right: [done])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: Self.width),
            page.heightAnchor.constraint(equalToConstant: 640),
        ])
        view = page
    }
}

/// An entry: a disclosure button with name, version and license; open, the link and the full license text.
private final class EntryView: NSStackView {
    private let entry: Acknowledgements.Entry
    private let license: String
    private let width: CGFloat
    private var detail: NSView?
    private let disclosure = NSButton()

    init(entry: Acknowledgements.Entry, license: String, width: CGFloat) {
        self.entry = entry
        self.license = license
        self.width = width
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.setAccessibilityLabel(entry.name)
        disclosure.setAccessibilityHelp("Shows the license")
        let name = NSTextField.label(entry.name)
        let info = NSTextField.label(
            [entry.version, entry.license].filter { !$0.isEmpty }.joined(separator: " · "),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor
        )
        let text = NSStackView.vertical([name, info], spacing: 2)
        let head = NSStackView.horizontal([disclosure, text], spacing: 6, alignment: .top)
        // A click on the name opens it too.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clickedHead))
        text.addGestureRecognizer(click)
        addArrangedSubview(head)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clickedHead() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggle()
    }

    @objc private func toggle() {
        let isOpen = disclosure.state == .on
        disclosure.setAccessibilityHelp(isOpen ? "Hides the license" : "Shows the license")
        if isOpen, detail == nil {
            detail = makeDetail()
            if let detail { addArrangedSubview(detail) }
        }
        detail?.isHidden = !isOpen
    }

    private func makeDetail() -> NSView {
        var views: [NSView] = []
        if let url = URL(string: entry.url) {
            let link = NSTextField(labelWithAttributedString: NSAttributedString(string: entry.url, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ]))
            link.isSelectable = true
            link.allowsEditingTextAttributes = true
            link.lineBreakMode = .byTruncatingMiddle
            link.translatesAutoresizingMaskIntoConstraints = false
            link.widthAnchor.constraint(lessThanOrEqualToConstant: width - 24).isActive = true
            views.append(link)
        }
        let text = NSTextField(wrappingLabelWithString: license)
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.isSelectable = true
        text.preferredMaxLayoutWidth = width - 48
        let panel = NSBox()
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = 8
        panel.contentViewMargins = NSSize(width: 12, height: 12)
        panel.contentView = text
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        views.append(panel)
        let stack = NSStackView.vertical(views, spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
        return stack
    }
}

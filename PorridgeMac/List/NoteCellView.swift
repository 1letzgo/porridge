import AppKit

/// A note in the middle column: the icon of its kind, title, a preview of two lines and a footer with the date,
/// the site, the length and its state. An entry in the inbox names its suggested bowl at the end of the footer
/// ("✦ Reading"); a click files it there.
/// The cell follows its note: a title typed in the detail shows here at once.
final class NoteCellView: NSTableCellView {
    private var leading: NSLayoutConstraint!
    static let identifier = NSUserInterfaceItemIdentifier("note")

    private let icon = KindIconView()
    private let todoBox = TodoCheckboxButton()
    private let titleLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium))
    private let previewLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor, lines: 2)
    /// What a document is: "Invoice · Telekom · 119,00 € · 2 Mar 2026".
    private let documentLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium), color: .brandNavy)
    private let footerLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private let badge = StateBadge()
    private let thumbnail = NSImageView()
    /// "✦ Bowl": the suggested bowl of an Inbox entry, a click files it (with the one undo toast and ⌘Z).
    private let suggestion = NSButton()
    private var suggestionKey: String?
    private var observing: Observing?
    private(set) var noteID: UUID?
    private var namesBuckets = false
    private var thumbnailFile: String?
    /// The footer's width: that of the text, or, beside a picture, on to the picture's trailing edge and below it.
    private var footerBesideText: NSLayoutConstraint!
    private var footerUnderPicture: [NSLayoutConstraint] = []

    /// Ticks a to-do from its box in the row.
    var onToggleDone: ((Note) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 7
        thumbnail.layer?.masksToBounds = true
        thumbnail.setAccessibilityElement(false)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        documentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        documentLabel.lineBreakMode = .byTruncatingTail
        todoBox.target = self
        todoBox.action = #selector(toggleDone)

        suggestion.isBordered = false
        suggestion.target = self
        suggestion.action = #selector(fileSuggested)
        suggestion.imagePosition = .imageLeading
        suggestion.setButtonType(.momentaryChange)
        suggestion.lineBreakMode = .byTruncatingTail
        suggestion.isHidden = true
        suggestion.setAccessibilityIdentifier("SuggestedBowl")
        // In the narrow list (260 pt) a long name is cut off rather than pushing the badge past the edge.
        suggestion.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        suggestion.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        let footer = NSStackView.horizontal([footerLabel, NSView(), badge, suggestion], spacing: 6)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)
        let text = NSStackView.vertical([titleLabel, documentLabel, previewLabel, footer], spacing: 3)
        // The text takes the width of the row; the box and the picture keep theirs at the end.
        text.setHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setCustomSpacing(5, after: previewLabel)
        // A to-do keeps the icon of its kind; the box that ticks it stands apart, at the end of the row.
        todoBox.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView.horizontal([icon, text, thumbnail, todoBox], spacing: 12, alignment: .top)
        row.setCustomSpacing(10, after: thumbnail)
        row.distribution = .fill
        addSubview(row)
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            todoBox.widthAnchor.constraint(equalToConstant: 30),
            todoBox.heightAnchor.constraint(equalToConstant: 30),
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
            documentLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 44),
            thumbnail.heightAnchor.constraint(equalToConstant: 44),
        ])
        // The status ends at the row's trailing edge in every row, also under a picture.
        footerBesideText = footer.widthAnchor.constraint(equalTo: text.widthAnchor)
        footerBesideText.isActive = true
        footerUnderPicture = [
            footer.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
            footer.topAnchor.constraint(greaterThanOrEqualTo: thumbnail.bottomAnchor, constant: 3),
        ]
        textField = titleLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the note and follows it until another one is shown.
    /// `namesBuckets`: the row names its bowls in place of the date (a list that mixes bowls, the to-dos folder).
    /// Under an appointment (Today): moved in a little, as belonging to it.
    var isIndented = false {
        didSet { leading.constant = isIndented ? 34 : 10 }
    }

    /// `showsSuggestions`: the Inbox's list (how long it waits, "✦ Bowl").
    func show(_ note: Note, buckets: [NoteFolder], showsSuggestions: Bool, namesBuckets: Bool = false) {
        self.namesBuckets = namesBuckets
        noteID = note.id
        observing?.cancel()
        observing = Observing { [weak self, weak note] in
            guard let self, let note, note.modelContext != nil || note.isEmptyLeftover == false else { return }
            self.render(note, buckets: buckets, showsSuggestions: showsSuggestions)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observing?.cancel()
        observing = nil
        noteID = nil
    }

    private func render(_ note: Note, buckets: [NoteFolder], showsSuggestions: Bool) {
        let processing = Library.shared.processing
        let isTodo = TodoBridge.isTodo(note)
        icon.symbol = NoteKindStyle.symbol(for: note)
        icon.tint = NoteKindStyle.tint(for: note)
        icon.isPinned = note.isPinned
        todoBox.isHidden = !isTodo
        if isTodo {
            todoBox.isDone = TodoBridge.isDone(note)
            todoBox.isEnabled = !note.isDeleted && !BowlSharing.shared.isReadOnly(note)
        }
        // A done to-do is struck through and grey.
        let done = isTodo && TodoBridge.isDone(note)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        titleLabel.attributedStringValue = NSAttributedString(string: note.displayTitle, attributes: [
            .paragraphStyle: titleStyle,
            .font: titleLabel.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium),
            .foregroundColor: done ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .strikethroughStyle: done ? NSUnderlineStyle.single.rawValue : 0,
        ])
        let document = note.isDocument ? note.documentInfo.flatMap { $0.isEmpty ? nil : $0.line } : nil
        documentLabel.stringValue = document ?? ""
        documentLabel.isHidden = document == nil
        let preview = note.preview
        previewLabel.stringValue = preview
        previewLabel.isHidden = preview.isEmpty
        previewLabel.maximumNumberOfLines = document == nil ? 2 : 1
        footerLabel.attributedStringValue = footer(note, inInbox: showsSuggestions)

        let stage = processing.stages[note.id]
        if let stage {
            badge.show(stage, color: .controlAccentColor, spinning: true)
        } else if note.status == .failed {
            badge.show("Failed", color: .brandDangerText)
        } else if [.recorded, .transcribing].contains(note.status), note.isRecording {
            badge.show(AudioStore.isLocal(note.audioFileName) ? "Waiting for transcription" : "Processing on another device")
        } else if case let waiting = note.pendingTodoSuggestions(made: []).count, waiting > 0 {
            // A summary with to-dos waiting to be taken on says so instead of "Summarized".
            badge.show(waiting == 1 ? "1 suggested to-do" : "\(waiting) suggested to-dos", color: .brandTaskText, symbol: "checklist")
        } else if note.summary != nil {
            badge.show("Summarized", color: .brandSkyText)
        } else {
            badge.show(nil)
        }

        // The first picture or PDF of the note, small.
        let attachment = note.attachmentsData == nil ? nil : note.attachments.first { $0.kind != .file }
        thumbnail.isHidden = attachment == nil
        if attachment == nil {
            NSLayoutConstraint.deactivate(footerUnderPicture)
            footerBesideText.isActive = true
        } else {
            footerBesideText.isActive = false
            NSLayoutConstraint.activate(footerUnderPicture)
        }
        if let attachment, attachment.fileName != thumbnailFile {
            thumbnailFile = attachment.fileName
            thumbnail.image = nil
            if let cached = Thumbnails.cached(attachment, maxPixels: 120) {
                thumbnail.image = NSImage(cgImage: cached, size: .zero)
            } else {
                let id = note.id
                Task { @MainActor [weak self] in
                    let image = await Thumbnails.load(attachment, maxPixels: 120)
                    guard let self, self.noteID == id, let image else { return }
                    self.thumbnail.image = NSImage(cgImage: image, size: .zero)
                }
            }
        } else if attachment == nil {
            thumbnailFile = nil
        }

        // The bowl suggested for an inbox entry, as one violet word at the end of the footer.
        let suggested = showsSuggestions ? EntryMeta.suggestion(for: note, bowls: buckets) : nil
        suggestionKey = suggested.map(Projects.key)
        suggestion.isHidden = suggested == nil
        if let suggested {
            let color = NSColor.brandProject.readable
            let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            suggestion.image = .symbol("sparkles", size: font.pointSize, weight: .semibold).tinted(color)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            suggestion.attributedTitle = NSAttributedString(string: suggested.name, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            suggestion.toolTip = String(localized: "File into “\(suggested.name)”")
            suggestion.setAccessibilityLabel(String(localized: "File into \(suggested.name)"))
        }

        setAccessibilityLabel([isTodo ? (done ? "Done To-do" : "To-do") : NoteKindStyle.name(for: note), note.displayTitle, preview, TodoBridge.dueAccessibility(of: note), footerLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Date, progress, due day, site, length: one line, the due day colored by where it stands.
    private func footer(_ note: Note, inInbox: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString()
        func add(_ text: String, symbol: String? = nil, color: NSColor = .secondaryLabelColor, bold: Bool = false) {
            if result.length > 0 { result.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
            let partFont = bold ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
            if let symbol {
                let attachment = NSTextAttachment()
                let image = NSImage.symbol(symbol, size: font.pointSize, weight: bold ? .semibold : .regular).tinted(color)
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: partFont]))
            }
            result.append(NSAttributedString(string: text, attributes: [.font: partFont, .foregroundColor: color]))
        }
        if let deletedAt = note.deletedAt {
            let passed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
            let left = max(0, NoteStore.trashDays - passed)
            add(left <= 1 ? String(localized: "Deleted tomorrow") : String(localized: "\(left) days left"), color: .brandDangerText)
        } else {
            // A to-do that names its bowls lets its due day speak for it; the date makes room for the names.
            if !(bucketNames(note).isEmpty == false && note.isTodo) {
                add(note.updatedAt.formatted(.dateTime.day().month(.abbreviated)) + " " + note.updatedAt.formatted(.dateTime.hour().minute()))
            }
            // Put away for later, back from it, or, in the Inbox, how long it has been waiting there.
            if note.isSnoozed(), let until = note.snoozedUntil {
                add(String(localized: "Later: back \(InboxSnooze.timeLabel(until))"), symbol: "clock", color: .brandNavy)
            } else if note.isBackFromLater() {
                add(String(localized: "Back from Later"), symbol: "clock.arrow.circlepath", color: .brandSkyText, bold: true)
            } else if inInbox, note.isInInbox, let waiting = InboxSnooze.waitingLabel(since: note.createdAt) {
                add(waiting, symbol: "hourglass")
            }
        }
        if TodoBridge.isTodo(note) {
            // The due day: red when late, green today, quiet otherwise; a done to-do is never marked.
            if let due = TodoBridge.due(of: note) {
                let status = TodoBridge.dueStatus(of: note)
                add(TodoBridge.dueLabel(due), symbol: status == .overdue ? "calendar.badge.exclamationmark" : "calendar",
                    color: status == .overdue ? .brandDangerText : status == .today ? .brandTaskText : .secondaryLabelColor,
                    bold: status == .overdue || status == .today)
            }
            let progress = TodoBridge.progress(of: note)
            if progress.total > 0 {
                add(progress.label, symbol: "checkmark.circle", color: progress.isComplete ? .brandTaskText : .secondaryLabelColor)
            }
        }
        let names = bucketNames(note)
        if !names.isEmpty { add(names.joined(separator: ", "), symbol: "folder", color: .brandProject.readable) }
        if let domain = note.domain { add(domain) }
        if note.isRecording, note.duration > 0 {
            add(note.duration.durationText)
            if note.speakers.count > 1 { add(String(localized: "\(note.speakers.count) speakers")) }
        }
        // Someone else added or changed it in a shared bowl, and it was not opened here since.
        if let activity = BowlSharing.shared.activityLine(for: note) {
            add(activity, symbol: "person.crop.circle.badge.exclamationmark", color: .brandProject.readable, bold: true)
        }
        // One line, cut at the end (an attributed text would wrap by default).
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func bucketNames(_ note: Note) -> [String] {
        guard namesBuckets else { return [] }
        return note.projectIDs.compactMap { Library.shared.project(key: $0)?.name }
    }

    @objc private func fileSuggested() {
        guard let id = noteID, let note = Library.shared.note(id), let key = suggestionKey else { return }
        Undoable.move([note], toBowl: key, named: Library.shared.project(key: key)?.name, in: Library.shared.context)
    }

    @objc private func toggleDone() {
        guard let id = noteID, let note = Library.shared.note(id) else { return }
        onToggleDone?(note)
    }
}

/// The round box of a to-do, in the list and the detail: green and ticked when done.
final class TodoCheckboxButton: NSButton {
    var isDone = false { didSet { needsDisplay = true; updateAccessibility() } }
    var isPinned = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateAccessibility() {
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(isDone ? "Done" : "Not Done")
        setAccessibilityValue(isDone ? 1 : 0)
        toolTip = isDone ? "Mark as Not Done" : "Mark as Done"
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height) - 4
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.28, yRadius: side * 0.28)
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        if isDone {
            NSColor.brandTask.withAlphaComponent(alpha).setFill()
            path.fill()
            let check = NSImage.symbol("checkmark", size: side * 0.55, weight: .bold).tinted(NSColor.brandOnFill.withAlphaComponent(alpha))
            check.draw(in: NSRect(x: rect.midX - check.size.width / 2, y: rect.midY - check.size.height / 2, width: check.size.width, height: check.size.height))
        } else {
            NSColor.brandTask.withAlphaComponent((isHighlighted ? 0.3 : 0.08) * alpha).setFill()
            path.fill()
            NSColor.brandTaskText.withAlphaComponent(alpha).setStroke()
            path.lineWidth = 1.6
            path.stroke()
        }
        if isPinned {
            let dot = NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 9, height: 9)
            NSColor.brandNavy.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

import AppKit

/// The transcript of a meeting as chat bubbles (`TranscriptBubbles`): one per passage, the user's on the right, the
/// others' on the left, the speaker's name where the speaker changes. A click plays the recording from there; the
/// passage being played is marked. A click on a speaker's name names it (`onSpeaker`); the context menu
/// copies a passage or gives it to another speaker.
final class TranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onPlay: ((TranscriptSegment) -> Void)?
    var onAssign: ((TranscriptSegment, Speaker) -> Void)?
    /// The speaker's name of a passage was clicked (the name's button, to show a menu at).
    var onSpeaker: ((TranscriptSegment, Speaker, NSView) -> Void)?
    var canAssign = true

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let message = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private var segments: [TranscriptSegment] = []
    private var speakers: [Speaker] = []
    private var styles: [TranscriptBubbles.RowStyle] = []
    private var activeRow = -1
    private var canPlay = false
    /// The width the rows were measured for: another one measures them again.
    private var measuredWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("segment"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Transcript")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(message)
        scroll.pinEdges(to: self)
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width a row's cell gets: the column's.
    private var rowWidth: CGFloat {
        table.tableColumns.first?.width ?? table.bounds.width
    }

    /// A row's height comes from its text wrapped at its bubble's width: a new width (the window resized) fits the
    /// bubbles to it and measures the rows again.
    override func layout() {
        super.layout()
        let width = rowWidth
        guard width > 0, abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        guard !segments.isEmpty else { return }
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? SegmentCell)?.fit(to: width)
        }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<segments.count))
    }

    func show(_ segments: [TranscriptSegment], speakers: [Speaker], emptyMessage: String, canPlay: Bool) {
        self.canPlay = canPlay
        let changed = segments != self.segments || speakers != self.speakers
        self.segments = segments
        self.speakers = speakers
        message.stringValue = emptyMessage
        message.isHidden = !segments.isEmpty
        scroll.isHidden = segments.isEmpty
        if changed {
            styles = TranscriptBubbles.rows(speakerIDs: segments.map(\.speakerId), meIDs: TranscriptBubbles.meIDs(in: speakers))
            activeRow = -1
            table.reloadData()
        }
    }

    /// Marks the passage at the time the recording plays at (none while it does not play).
    func highlight(time: TimeInterval?) {
        let row = time.flatMap { t in segments.firstIndex { t >= $0.start && t < $0.end } } ?? -1
        guard row != activeRow else { return }
        let old = activeRow
        activeRow = row
        for index in [old, row] where index >= 0 && index < segments.count {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SegmentCell)?.isActive = index == row
        }
        if row >= 0 { table.scrollRowToVisible(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SegmentCell.identifier, owner: nil) as? SegmentCell ?? SegmentCell()
        let segment = segments[row]
        let speaker = speakers.first { $0.id == segment.speakerId }
        let style = row < styles.count ? styles[row] : TranscriptBubbles.RowStyle(side: .leading, showsName: true)
        cell.show(segment, speaker: speaker, style: style, canPlay: canPlay, width: rowWidth)
        cell.onName = canAssign && speaker != nil ? { [weak self] anchor in
            guard let self, let speaker else { return }
            self.onSpeaker?(segment, speaker, anchor)
        } : nil
        cell.isActive = row == activeRow
        return cell
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard canPlay, row >= 0, row < segments.count else { return }
        onPlay?(segments[row])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < segments.count else { return }
        let segment = segments[row]
        menu.add("Copy", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        }
        if canPlay {
            menu.add("Play from Here", symbol: "play") { [weak self] in self?.onPlay?(segment) }
        }
        if speakers.count > 1, canAssign {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Assign Speaker"))
            for speaker in speakers {
                let item = menu.add(speaker.name) { [weak self] in self?.onAssign?(segment, speaker) }
                item.state = segment.speakerId == speaker.id ? .on : .off
            }
        }
    }
}

/// One passage as a bubble on its speaker's side, at most `TranscriptBubbles.maximumWidth` of the width: a tint of
/// the speaker's color, the speaker (where it changes) and the time on top, the text below.
private final class SegmentCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("segment")
    private let box = NSView()
    private let dot = NSView()
    private let name = NSButton()
    /// A click on the name; nil: the name is plain text.
    var onName: ((NSView) -> Void)?
    private let me = NSTextField.label(font: .systemFont(ofSize: 10, weight: .bold), color: .brandOnFill)
    private let time = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
    private let text = NSTextField(wrappingLabelWithString: "")
    private var head: NSStackView!
    private var tint: NSColor = .systemGray
    private var leadingEdge: NSLayoutConstraint!
    private var trailingEdge: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    /// The bubble's width, from its text and its head line (`fit`).
    private var boxWidth: NSLayoutConstraint!
    /// What the bubble was last fitted to: width of the row, text, head.
    private var fitted: (width: CGFloat, text: String, head: CGFloat)?
    private static let minimumBoxWidth: CGFloat = 120
    private static let inset: CGFloat = 14
    var isActive = false { didSet { updateLayer() } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        me.stringValue = "Me"
        me.wantsLayer = true
        me.layer?.cornerRadius = 6
        me.layer?.backgroundColor = NSColor.brandTask.cgColor
        me.alignment = .center
        me.setAccessibilityLabel("You")
        name.isBordered = false
        name.target = self
        name.action = #selector(nameClicked)
        name.setContentHuggingPriority(.required, for: .horizontal)
        text.font = .preferredFont(forTextStyle: .body)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView.horizontal([dot, name, me, NSView(), time], spacing: 8)
        self.head = head
        let stack = NSStackView.vertical([head, text], spacing: 6)
        box.addSubview(stack)
        addSubview(box)
        leadingEdge = box.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingEdge = box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        top = box.topAnchor.constraint(equalTo: topAnchor)
        // As narrow as its text allows (a short passage is a small bubble), set by `fit`. The text is measured at
        // exactly the width it is drawn at, so the row is as high as its lines.
        boxWidth = box.widthAnchor.constraint(equalToConstant: Self.minimumBoxWidth)
        boxWidth.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            me.widthAnchor.constraint(equalToConstant: 26),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            box.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: TranscriptBubbles.maximumWidth),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumBoxWidth),
            boxWidth,
            top,
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingEdge,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        box.layer?.backgroundColor = (isActive ? NSColor.brandSky.withAlphaComponent(0.22) : tint.withAlphaComponent(0.1)).resolved(for: self)
        dot.layer?.backgroundColor = tint.resolved(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    /// A wrapping label needs the width it is drawn at to know its height.
    override func layout() {
        fit(to: bounds.width)
        super.layout()
    }

    /// Sizes the bubble for a row `width` wide: at most `TranscriptBubbles.maximumWidth` of it, as narrow as the
    /// wrapped text or the head line allow, and the text measured at exactly the width it gets in the bubble.
    func fit(to width: CGFloat) {
        guard width > 0 else { return }
        let headWidth = ceil(head.fittingSize.width)
        if let fitted, abs(fitted.width - width) < 0.5, fitted.text == text.stringValue, abs(fitted.head - headWidth) < 0.5 { return }
        fitted = (width, text.stringValue, headWidth)
        let widest = max(Self.minimumBoxWidth, floor(width * TranscriptBubbles.maximumWidth) - 2) - 2 * Self.inset
        let natural = text.cell.map { ceil($0.cellSize(forBounds: NSRect(x: 0, y: 0, width: widest, height: .greatestFiniteMagnitude)).width) } ?? widest
        let content = min(widest, max(natural, headWidth, Self.minimumBoxWidth - 2 * Self.inset))
        if abs(boxWidth.constant - (content + 2 * Self.inset)) > 0.5 { boxWidth.constant = content + 2 * Self.inset }
        if abs(text.preferredMaxLayoutWidth - content) > 0.5 {
            text.preferredMaxLayoutWidth = content
            text.invalidateIntrinsicContentSize()
        }
    }

    @objc private func nameClicked() { onName?(name) }

    func show(_ segment: TranscriptSegment, speaker: Speaker?, style: TranscriptBubbles.RowStyle, canPlay: Bool, width: CGFloat) {
        tint = speaker.map { NSColor.speaker($0.colorIndex) } ?? .systemGray
        let trailing = style.side == .trailing
        leadingEdge.isActive = !trailing
        trailingEdge.isActive = trailing
        // A new speaker gets a little more room above.
        top.constant = style.showsName ? 8 : 0
        let showsName = style.showsName && speaker != nil
        dot.isHidden = !showsName
        name.isHidden = !showsName
        let title = NSMutableAttributedString(string: speaker?.name ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.brandNavy,
        ])
        // An unnamed speaker invites a name.
        if let speaker, VoiceProfiles.isUnnamed(speaker) {
            title.append(NSAttributedString(string: "  " + String(localized: "Name…"), attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        name.attributedTitle = title
        name.toolTip = speaker.map { String(localized: "Name \($0.name)") }
        name.setAccessibilityLabel(speaker.map { String(localized: "Speaker \($0.name)") })
        me.isHidden = !(showsName && (speaker.map(AppSettings.isMe) ?? false))
        time.stringValue = segment.start.clockString
        text.stringValue = segment.text
        fit(to: width)
        updateLayer()
        setAccessibilityElement(true)
        setAccessibilityRole(canPlay ? .button : .group)
        // The name is read for every passage, also where it is not shown.
        setAccessibilityLabel([speaker?.name, segment.start.clockString, segment.text].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityHelp(canPlay ? "Plays the recording from here." : "")
    }
}

/// Play and pause, 15 seconds back and ahead, the position, and deleting the recording.
final class PlayerBarView: NSView {
    private let player: AudioPlayback
    private let play = NSButton()
    private let slider = NSSlider()
    private let time = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
    private var observing: Observing?
    var onDelete: (() -> Void)?

    init(player: AudioPlayback) {
        self.player = player
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        play.bezelStyle = .circular
        play.controlSize = .large
        play.target = self
        play.action = #selector(togglePlay)
        play.contentTintColor = .brandNavy
        let back = NSButton(image: .symbol("gobackward.15", size: 15, weight: .semibold, label: "Back 15 Seconds"), target: self, action: #selector(backward))
        let ahead = NSButton(image: .symbol("goforward.15", size: 15, weight: .semibold, label: "Ahead 15 Seconds"), target: self, action: #selector(forward))
        let delete = NSButton(image: .symbol("trash", size: 13, weight: .regular, label: "Delete Recording"), target: self, action: #selector(deleteRecording))
        for button in [back, ahead, delete] {
            button.isBordered = false
            button.contentTintColor = .brandNavy
        }
        delete.contentTintColor = .brandDangerText
        delete.toolTip = "Delete Recording…"
        back.toolTip = "Back 15 Seconds"
        ahead.toolTip = "Ahead 15 Seconds"
        slider.target = self
        slider.action = #selector(seek)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Position")
        let row = NSStackView.horizontal([play, back, ahead, slider, time, delete], spacing: 12)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 14))
        observing = Observing { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.resolved(for: self)
        layer?.borderColor = NSColor.separatorColor.resolved(for: self)
    }

    func stopObserving() {
        observing?.cancel()
    }

    private func render() {
        play.image = .symbol(player.isPlaying ? "pause.fill" : "play.fill", size: 15, weight: .semibold, label: player.isPlaying ? "Pause" : "Play")
        play.toolTip = player.isPlaying ? "Pause" : "Play"
        slider.maxValue = max(player.duration, 1)
        if slider.currentEditor() == nil { slider.doubleValue = player.currentTime }
        time.stringValue = player.currentTime.clockString
        slider.setAccessibilityValue(player.currentTime.clockString)
    }

    @objc private func togglePlay() { player.toggle() }
    @objc private func backward() { player.skip(-15) }
    @objc private func forward() { player.skip(15) }
    @objc private func seek() { player.seek(to: slider.doubleValue) }
    @objc private func deleteRecording() { onDelete?() }
}

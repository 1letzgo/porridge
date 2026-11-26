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
    /// Row heights at `measuredWidth`, measured with `sizingCell`.
    private var heights: [Int: CGFloat] = [:]
    /// A cell that is never shown: it measures rows (`tableView(_:heightOfRow:)`).
    private lazy var sizingCell = SegmentCell()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("segment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // Heights come from `heightOfRow`: the same sizes the shown cell is laid out with, so a bubble is exactly as
        // high as its head line and its wrapped text.
        table.usesAutomaticRowHeights = false
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
        scroll.hasHorizontalScroller = false
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

    /// The width a row's cell gets: the column's (the visible width until the table has sized its column).
    private var rowWidth: CGFloat {
        let column = table.tableColumns.first?.width ?? 0
        return column > 0 ? column : scroll.contentView.bounds.width
    }

    override func layout() {
        super.layout()
        refitIfWidthChanged()
    }

    /// The column got another width (the window or a column of it resized).
    func tableViewColumnDidResize(_ notification: Notification) {
        refitIfWidthChanged()
    }

    /// A new width sizes the shown bubbles for it and measures every row again.
    private func refitIfWidthChanged() {
        let width = rowWidth
        guard width > 0, abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        heights = [:]
        guard !segments.isEmpty else { return }
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? SegmentCell)?.apply(width: width)
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
            heights = [:]
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

    private func configure(_ cell: SegmentCell, row: Int) {
        let segment = segments[row]
        let speaker = speakers.first { $0.id == segment.speakerId }
        let style = row < styles.count ? styles[row] : TranscriptBubbles.RowStyle(side: .leading, showsName: true)
        cell.show(segment, speaker: speaker, style: style, canPlay: canPlay)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < segments.count else { return 20 }
        let width = rowWidth
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            heights = [:]
        }
        if let height = heights[row] { return height }
        configure(sizingCell, row: row)
        let height = sizingCell.metrics(for: width).height
        heights[row] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SegmentCell.identifier, owner: nil) as? SegmentCell ?? SegmentCell()
        configure(cell, row: row)
        cell.apply(width: rowWidth)
        let segment = segments[row]
        let speaker = speakers.first { $0.id == segment.speakerId }
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
/// the speaker's color, the speaker (where it changes) and the time on top in one line, the text below.
///
/// Its sizes come from `metrics(for:)`, for the shown cell (`apply`) and for measuring a row alike: the bubble is as
/// wide as its text or its head line (whichever is wider, at most the maximum), the text wraps at exactly that width,
/// and the row is as high as the head line and those lines. The head line never wraps: a name too long for it is
/// cut with "…".
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
    private let head: NSStackView
    private var tint: NSColor = .systemGray
    private var leadingEdge: NSLayoutConstraint!
    private var trailingEdge: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    /// The bubble's width (`apply`).
    private var boxWidth: NSLayoutConstraint!
    private static let minimumBoxWidth: CGFloat = 120
    private static let inset: CGFloat = 14
    private static let insetTop: CGFloat = 10
    private static let insetBottom: CGFloat = 12
    private static let lineSpacing: CGFloat = 6
    /// Room kept free at the trailing edge (the user's bubbles end 2 pt before it).
    private static let edgeGap: CGFloat = 2
    var isActive = false { didSet { updateLayer() } }

    struct Metrics {
        /// Width of the bubble, and of its text and head line inside it.
        let box: CGFloat
        let content: CGFloat
        /// Height of the row.
        let height: CGFloat
    }

    init() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        head = NSStackView.horizontal([dot, name, me, spacer, time], spacing: 8)
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
        // One line: the name is cut with "…" rather than broken over lines.
        name.cell?.wraps = false
        name.cell?.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        name.usesSingleLineMode = true
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        for fixed in [dot, me, time] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // The gap between name and time takes what is left and is the first to give way.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        text.font = .preferredFont(forTextStyle: .body)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView.vertical([head, text], spacing: Self.lineSpacing)
        box.addSubview(stack)
        addSubview(box)
        leadingEdge = box.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingEdge = box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeGap)
        top = box.topAnchor.constraint(equalTo: topAnchor)
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
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.insetTop),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.insetBottom),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            box.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.edgeGap),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: TranscriptBubbles.maximumWidth),
            boxWidth,
            top,
            // The row is measured to fit the bubble; it never stretches it.
            box.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
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

    /// The bubble's sizes in a row `width` wide: the head line in one line at its natural width, the text measured
    /// at the widest the bubble may be; the bubble takes the wider of the two (at most the maximum), and the text's
    /// height is measured again at exactly that width.
    func metrics(for width: CGFloat) -> Metrics {
        let widest = max(Self.minimumBoxWidth, floor(width * TranscriptBubbles.maximumWidth) - Self.edgeGap) - 2 * Self.inset
        let headSize = head.fittingSize
        let unbounded = CGFloat.greatestFiniteMagnitude
        let natural = text.cell.map { ceil($0.cellSize(forBounds: NSRect(x: 0, y: 0, width: widest, height: unbounded)).width) } ?? widest
        let content = min(widest, max(natural, ceil(headSize.width), Self.minimumBoxWidth - 2 * Self.inset))
        let textHeight = text.cell.map { ceil($0.cellSize(forBounds: NSRect(x: 0, y: 0, width: content, height: unbounded)).height) } ?? 0
        let height = top.constant + Self.insetTop + ceil(headSize.height) + Self.lineSpacing + textHeight + Self.insetBottom
        return Metrics(box: content + 2 * Self.inset, content: content, height: ceil(height))
    }

    /// Sizes the bubble for a row `width` wide (`metrics`).
    func apply(width: CGFloat) {
        guard width > 0 else { return }
        let metrics = metrics(for: width)
        if abs(boxWidth.constant - metrics.box) > 0.5 { boxWidth.constant = metrics.box }
        if abs(text.preferredMaxLayoutWidth - metrics.content) > 0.5 {
            text.preferredMaxLayoutWidth = metrics.content
            text.invalidateIntrinsicContentSize()
        }
    }

    @objc private func nameClicked() { onName?(name) }

    func show(_ segment: TranscriptSegment, speaker: Speaker?, style: TranscriptBubbles.RowStyle, canPlay: Bool) {
        tint = speaker.map { NSColor.speaker($0.colorIndex) } ?? .systemGray
        let trailing = style.side == .trailing
        leadingEdge.isActive = !trailing
        trailingEdge.isActive = trailing
        // A new speaker gets a little more room above.
        top.constant = style.showsName ? 8 : 0
        let showsName = style.showsName && speaker != nil
        dot.isHidden = !showsName
        name.isHidden = !showsName
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: speaker?.name ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.brandNavy,
            .paragraphStyle: oneLine,
        ])
        // An unnamed speaker invites a name.
        if let speaker, VoiceProfiles.isUnnamed(speaker) {
            title.append(NSAttributedString(string: "  " + String(localized: "Name…"), attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: oneLine,
            ]))
        }
        name.attributedTitle = title
        name.toolTip = speaker.map { String(localized: "Name \($0.name)") }
        name.setAccessibilityLabel(speaker.map { String(localized: "Speaker \($0.name)") })
        me.isHidden = !(showsName && (speaker.map(AppSettings.isMe) ?? false))
        time.stringValue = segment.start.clockString
        text.stringValue = segment.text
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

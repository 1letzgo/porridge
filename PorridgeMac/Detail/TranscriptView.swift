import AppKit

/// The transcript of a meeting: one row per passage with speaker, time and text. A click plays the recording from
/// there; the passage being played is marked. The context menu copies a passage or gives it to another speaker.
final class TranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onPlay: ((TranscriptSegment) -> Void)?
    var onAssign: ((TranscriptSegment, Speaker) -> Void)?
    var canAssign = true

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let message = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private var segments: [TranscriptSegment] = []
    private var speakers: [Speaker] = []
    private var activeRow = -1
    private var canPlay = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("segment"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 10)
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

    func show(_ segments: [TranscriptSegment], speakers: [Speaker], emptyMessage: String, canPlay: Bool) {
        self.canPlay = canPlay
        let changed = segments != self.segments || speakers != self.speakers
        self.segments = segments
        self.speakers = speakers
        message.stringValue = emptyMessage
        message.isHidden = !segments.isEmpty
        scroll.isHidden = segments.isEmpty
        if changed {
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
        cell.show(segment, speaker: speakers.first { $0.id == segment.speakerId }, canPlay: canPlay)
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

/// One passage: a tint of the speaker's color, the speaker and the time on top, the text below.
private final class SegmentCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("segment")
    private let box = NSView()
    private let dot = NSView()
    private let name = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .brandNavy)
    private let me = NSTextField.label(font: .systemFont(ofSize: 10, weight: .bold), color: .brandOnFill)
    private let time = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
    private let text = NSTextField(wrappingLabelWithString: "")
    private var tint: NSColor = .systemGray
    var isActive = false { didSet { updateLayer() } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
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
        text.font = .preferredFont(forTextStyle: .body)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView.horizontal([dot, name, me, NSView(), time], spacing: 8)
        let stack = NSStackView.vertical([head, text], spacing: 6)
        box.addSubview(stack)
        addSubview(box)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            me.widthAnchor.constraint(equalToConstant: 26),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        box.layer?.backgroundColor = (isActive ? NSColor.brandSky.withAlphaComponent(0.22) : tint.withAlphaComponent(0.08)).resolved(for: self)
        dot.layer?.backgroundColor = tint.resolved(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    func show(_ segment: TranscriptSegment, speaker: Speaker?, canPlay: Bool) {
        tint = speaker.map { NSColor.speaker($0.colorIndex) } ?? .systemGray
        dot.isHidden = speaker == nil
        name.stringValue = speaker?.name ?? ""
        me.isHidden = !(speaker.map(AppSettings.isMe) ?? false)
        time.stringValue = segment.start.clockString
        text.stringValue = segment.text
        updateLayer()
        setAccessibilityElement(true)
        setAccessibilityRole(canPlay ? .button : .group)
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

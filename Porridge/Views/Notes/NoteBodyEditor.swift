import SwiftUI

/// Lets the note screen reach into the editor: cursor position and keyboard.
@MainActor
@Observable
final class NoteEditorController {
    @ObservationIgnored fileprivate var cursorProvider: (() -> Int)?
    @ObservationIgnored fileprivate var blurAction: (() -> Void)?
    /// A line of the body is being edited (the format bar is showing above the keyboard).
    fileprivate(set) var isEditing = false

    /// Cursor as a character offset in the note's Markdown; the end of the text when no line is being edited.
    var cursorOffset: Int { cursorProvider?() ?? 0 }

    func blur() { blurAction?() }
}

/// The body of a note as lines: every line is a normal text field, checklist boxes, bullets and numbers are real
/// controls. The note is still stored as Markdown; this view converts in both directions (see `NoteBlock`).
struct NoteBodyEditor: View {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController

    @State private var blocks: [NoteBlock]
    /// The Markdown this editor wrote last; a different `text` came from outside (dictation, sync) and is parsed again.
    @State private var lastWritten: String
    /// Bumped to make a field show the model text again after an edit that did not change it.
    @State private var version = 0
    @State private var selections: [UUID: TextSelection] = [:]
    @State private var pendingCommit: Task<Void, Never>?
    @FocusState private var focus: UUID?

    /// Every field starts with this invisible character. Deleting it is how a Backspace at the start of a line
    /// is noticed (a text field does not report that otherwise).
    private static let sentinel = "\u{200B}"

    init(text: Binding<String>, isEditable: Bool = true, controller: NoteEditorController) {
        _text = text
        self.isEditable = isEditable
        self.controller = controller
        _blocks = State(initialValue: NoteBlock.parse(text.wrappedValue))
        _lastWritten = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        let numbers = NoteBlock.numbers(for: blocks)
        VStack(spacing: 0) {
            #if os(macOS)
            if isEditable { formatBar.padding(.bottom, 6) }
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            row(block, number: numbers[index])
                        }
                        Color.clear
                            .frame(height: 220)
                            .contentShape(Rectangle())
                            .onTapGesture { focusEnd() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .dismissKeyboardOnScroll()
                .onChange(of: focus) { _, id in
                    controller.isEditing = id != nil
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } else { flush() }
                }
            }
        }
        .onChange(of: text) {
            if text != lastWritten {
                lastWritten = text
                blocks = NoteBlock.parse(text)
            }
        }
        .onDisappear { flush() }
        .onAppear {
            controller.cursorProvider = { [self] in cursorOffset() }
            controller.blurAction = { focus = nil }
        }
        #if os(iOS)
        .overlay(alignment: .bottom) {
            if focus != nil, isEditable { keyboardBar }
        }
        #endif
    }

    /// One bar over the keyboard with all the buttons, like in Notes.
    private var keyboardBar: some View {
        HStack {
            formatMenu
            Spacer()
            checklistButton
            Spacer()
            outdentButton
            Spacer()
            indentButton
            Spacer()
            Button("Done") { focus = nil }.fontWeight(.semibold)
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .frame(height: 52)
        .modifier(BarBackground())
        // The note screen has 16 pt of padding all around; the bar reaches out to 12 pt from the edge, 6 pt above the keyboard.
        .padding(.horizontal, -4)
        .padding(.bottom, -10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Rows

    private func row(_ block: NoteBlock, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(block, number: number)
            field(block)
        }
        .padding(.leading, CGFloat(block.indent) * 24)
        .padding(.top, topSpace(block))
        .padding(.bottom, 3)
        .id(block.id)
    }

    private func topSpace(_ block: NoteBlock) -> CGFloat {
        if case .heading = block.kind { return 10 }
        return 3
    }

    @ViewBuilder
    private func marker(_ block: NoteBlock, number: Int) -> some View {
        switch block.kind {
        case .bullet:
            Text("•").font(.body.weight(.bold))
        case .numbered:
            Text("\(number).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
        case .checklist(let checked):
            Button {
                toggleChecked(block.id)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            .accessibilityLabel(checked ? "Checked" : "Not checked")
            .accessibilityIdentifier("Checkbox")
        default:
            EmptyView()
        }
    }

    private func font(_ kind: NoteBlock.Kind) -> Font {
        switch kind {
        case .heading(1): .title.bold()
        case .heading(2): .title2.bold()
        case .heading: .title3.bold()
        default: .body
        }
    }

    private func field(_ block: NoteBlock) -> some View {
        let checked = block.kind == .checklist(checked: true)
        // Lines with Markdown marks (bold, tags, ...) are shown formatted while they are not being edited.
        let formatted = focus == block.id ? nil : rendered(block.text)
        return ZStack(alignment: .topLeading) {
            TextField("", text: rawBinding(block.id), selection: selectionBinding(block.id), axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focus, equals: block.id)
                .disabled(!isEditable)
                .opacity(formatted == nil ? 1 : 0)
                .accessibilityIdentifier("NoteBlock")
                .onKeyPress(keys: [.tab]) { press in
                    shift(block.id, deeper: !press.modifiers.contains(.shift))
                    return .handled
                }
                #if os(macOS)
                .onSubmit { splitAtCaret(block.id) }
                #endif
            if let formatted {
                Text(formatted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .font(font(block.kind))
        .strikethrough(checked)
        .foregroundStyle(checked ? Color.secondary : Color.primary)
        .padding(.leading, block.kind == .quote ? 12 : 0)
        .overlay(alignment: .leading) {
            if block.kind == .quote {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 3)
            }
        }
    }

    /// The line with its inline Markdown applied, or nil when it has no marks.
    private func rendered(_ line: String) -> AttributedString? {
        guard !line.isEmpty,
              var attributed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return nil }
        let plain = String(attributed.characters)
        let tags = NoteText.tagRanges(in: plain)
        guard plain != line || !tags.isEmpty else { return nil }
        for range in tags {
            guard let swiftRange = Range(range, in: plain) else { continue }
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: swiftRange.lowerBound))
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: swiftRange.upperBound))
            attributed[lower..<upper].foregroundColor = Color.accentColor
        }
        return attributed
    }

    // MARK: Bindings

    private func index(of id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }

    private func rawBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                _ = version
                return Self.sentinel + (blocks.first { $0.id == id }?.text ?? "")
            },
            set: { edit(id, raw: $0) }
        )
    }

    private func selectionBinding(_ id: UUID) -> Binding<TextSelection?> {
        Binding(
            get: { selections[id] },
            set: { newValue in
                guard let newValue else { selections[id] = nil; return }
                // The cursor never stays in front of the invisible character.
                if case .selection(let range) = newValue.indices, range.isEmpty,
                   let i = index(of: id) {
                    let line = Self.sentinel + blocks[i].text
                    if range.lowerBound == line.startIndex, range.upperBound <= line.endIndex {
                        selections[id] = TextSelection(insertionPoint: line.index(after: line.startIndex))
                        return
                    }
                }
                selections[id] = newValue
            }
        )
    }

    /// The selection of a line as character offsets in its text (without the invisible character).
    private func selectedOffsets(_ id: UUID) -> Range<Int>? {
        guard let selection = selections[id], let i = index(of: id) else { return nil }
        let line = Self.sentinel + blocks[i].text
        guard case .selection(let range) = selection.indices, range.upperBound <= line.endIndex else { return nil }
        let lower = max(0, line.distance(from: line.startIndex, to: range.lowerBound) - 1)
        let upper = max(lower, line.distance(from: line.startIndex, to: range.upperBound) - 1)
        return lower..<upper
    }

    private func cursorOffset() -> Int {
        guard let id = focus, let i = index(of: id) else { return NoteBlock.markdown(blocks).count }
        let caret = selectedOffsets(id)?.upperBound ?? blocks[i].text.count
        return NoteBlock.textOffset(of: i, in: blocks) + min(caret, blocks[i].text.count)
    }

    // MARK: Editing

    /// Hands the lines to the note shortly after the last change. Writing to the note on every key press makes the
    /// notes list update while typing, which makes the field drop letters.
    private func commit() {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { flush() }
        }
    }

    private func flush() {
        pendingCommit?.cancel()
        pendingCommit = nil
        let markdown = NoteBlock.markdown(blocks)
        lastWritten = markdown
        if text != markdown { text = markdown }
    }

    private func place(_ id: UUID, caret: Int? = nil) {
        Task { @MainActor in
            guard let i = index(of: id) else { return }
            let line = Self.sentinel + blocks[i].text
            let offset = 1 + min(caret ?? blocks[i].text.count, blocks[i].text.count)
            selections[id] = TextSelection(insertionPoint: line.index(line.startIndex, offsetBy: offset))
            focus = id
        }
    }

    private func focusEnd() {
        guard isEditable, var last = blocks.last else { return }
        if !last.text.isEmpty || last.kind != .paragraph {
            last = NoteBlock()
            blocks.append(last)
            commit()
        }
        place(last.id)
    }

    private func edit(_ id: UUID, raw: String) {
        guard let i = index(of: id) else { return }
        let hadSentinel = raw.hasPrefix(Self.sentinel)
        let value = raw.replacingOccurrences(of: Self.sentinel, with: "")
        let old = blocks[i].text
        if value == old {
            if !hadSentinel { backspaceAtStart(i) }
            return
        }
        if value.contains("\n") {
            split(i, value: value)
            return
        }
        blocks[i].text = value
        if blocks[i].kind == .paragraph, let converted = shortcut(for: value) {
            blocks[i].kind = converted.kind
            blocks[i].text = converted.text
            version += 1
            place(id, caret: 0)
        }
        commit()
    }

    /// Typing "- ", "1. ", "[] ", "# " or "> " at the start of a line turns it into that kind of line.
    private func shortcut(for value: String) -> (kind: NoteBlock.Kind, text: String)? {
        switch value {
        case "- ", "* ", "• ": return (.bullet, "")
        case "[] ", "- [ ] ": return (.checklist(checked: false), "")
        case "# ": return (.heading(1), "")
        case "## ": return (.heading(2), "")
        case "### ": return (.heading(3), "")
        case "> ": return (.quote, "")
        default:
            if value.count >= 3, value.hasSuffix(". "), value.dropLast(2).allSatisfy(\.isNumber) { return (.numbered, "") }
            return nil
        }
    }

    /// Return was pressed (or text with line breaks pasted): the line is split.
    private func split(_ i: Int, value: String) {
        let block = blocks[i]
        let parts = value.components(separatedBy: "\n")

        // Return on an empty item ends the list (one level at a time).
        if block.text.isEmpty, value == "\n", block.kind != .paragraph {
            if block.isList, block.indent > 0 {
                blocks[i].indent -= 1
            } else {
                blocks[i].kind = .paragraph
                blocks[i].indent = 0
            }
            version += 1
            commit()
            place(block.id, caret: 0)
            return
        }

        blocks[i].text = parts[0]
        var added: [NoteBlock] = []
        for part in parts.dropFirst() {
            if parts.count == 2 {
                var next = NoteBlock(text: part)
                switch block.kind {
                case .bullet, .numbered, .quote: next.kind = block.kind; next.indent = block.indent
                case .checklist: next.kind = .checklist(checked: false); next.indent = block.indent
                default: break
                }
                added.append(next)
            } else {
                added.append(NoteBlock.parse(line: part))
            }
        }
        blocks.insert(contentsOf: added, at: i + 1)
        version += 1
        commit()
        if let last = added.last { place(last.id, caret: parts.count == 2 ? 0 : nil) }
    }

    #if os(macOS)
    private func splitAtCaret(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let characters = Array(blocks[i].text)
        let caret = min(selectedOffsets(id)?.upperBound ?? characters.count, characters.count)
        split(i, value: String(characters[..<caret]) + "\n" + String(characters[caret...]))
    }
    #endif

    /// Backspace at the very start of a line: the mark goes first, then the line joins the one above.
    private func backspaceAtStart(_ i: Int) {
        let block = blocks[i]
        if block.kind != .paragraph {
            if block.isList, block.indent > 0 {
                blocks[i].indent -= 1
            } else {
                blocks[i].kind = .paragraph
                blocks[i].indent = 0
            }
            version += 1
            commit()
            place(block.id, caret: 0)
        } else if i > 0 {
            let previous = blocks[i - 1]
            let join = previous.text.count
            blocks[i - 1].text += block.text
            blocks.remove(at: i)
            version += 1
            commit()
            place(previous.id, caret: join)
        } else {
            version += 1
        }
    }

    private func toggleChecked(_ id: UUID) {
        guard let i = index(of: id), case .checklist(let checked) = blocks[i].kind else { return }
        blocks[i].kind = .checklist(checked: !checked)
        commit()
    }

    // MARK: Formatting

    private var formatBar: some View {
        HStack(spacing: 18) {
            formatMenu
            checklistButton
            outdentButton
            indentButton
        }
    }

    private var formatMenu: some View {
        Menu {
            Button("Title") { setKind(.heading(1)) }
            Button("Heading") { setKind(.heading(2)) }
            Button("Subheading") { setKind(.heading(3)) }
            Button("Body") { setKind(.paragraph) }
            Divider()
            Button { toggleInline("**") } label: { Label("Bold", systemImage: "bold") }
            Button { toggleInline("*") } label: { Label("Italic", systemImage: "italic") }
            Divider()
            Button { setKind(.bullet) } label: { Label("Bulleted List", systemImage: "list.bullet") }
            Button { setKind(.numbered) } label: { Label("Numbered List", systemImage: "list.number") }
            Button { setKind(.quote) } label: { Label("Quote", systemImage: "text.quote") }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Format")
    }

    private var checklistButton: some View {
        Button { setKind(.checklist(checked: false)) } label: { Image(systemName: "checklist") }
            .accessibilityLabel("Checklist")
    }

    private var outdentButton: some View {
        Button { shiftFocused(deeper: false) } label: { Image(systemName: "decrease.indent") }
            .accessibilityLabel("Outdent")
    }

    private var indentButton: some View {
        Button { shiftFocused(deeper: true) } label: { Image(systemName: "increase.indent") }
            .accessibilityLabel("Indent")
    }

    /// Makes the line being edited that kind; the same kind again turns it back into plain text.
    private func setKind(_ kind: NoteBlock.Kind) {
        guard let id = focus, let i = index(of: id) else { return }
        var same = blocks[i].kind == kind
        if case .checklist = kind, case .checklist = blocks[i].kind { same = true }
        blocks[i].kind = same ? .paragraph : kind
        if !blocks[i].isList { blocks[i].indent = 0 }
        commit()
    }

    private func shiftFocused(deeper: Bool) {
        if let id = focus { shift(id, deeper: deeper) }
    }

    private func shift(_ id: UUID, deeper: Bool) {
        guard let i = index(of: id), blocks[i].isList else { return }
        blocks[i].indent = min(NoteBlock.maxIndent, max(0, blocks[i].indent + (deeper ? 1 : -1)))
        commit()
    }

    /// Bold / italic around the selection (or the word at the cursor); again removes it.
    private func toggleInline(_ mark: String) {
        guard let id = focus, let i = index(of: id) else { return }
        var characters = Array(blocks[i].text)
        let m = mark.count
        var range = selectedOffsets(id) ?? characters.count..<characters.count
        range = min(range.lowerBound, characters.count)..<min(range.upperBound, characters.count)

        if range.isEmpty {
            func isWord(_ at: Int) -> Bool { at >= 0 && at < characters.count && (characters[at].isLetter || characters[at].isNumber) }
            var lower = range.lowerBound, upper = range.upperBound
            while isWord(lower - 1) { lower -= 1 }
            while isWord(upper) { upper += 1 }
            range = lower..<upper
        }

        func run(_ character: Character, from start: Int, step: Int) -> Int {
            var count = 0, at = start
            while at >= 0, at < characters.count, characters[at] == character { count += 1; at += step }
            return count
        }
        let before = run("*", from: range.lowerBound - 1, step: -1)
        let after = run("*", from: range.upperBound, step: 1)
        let wrapped = m == 2 ? (before >= 2 && after >= 2) : (before % 2 == 1 && after % 2 == 1)

        var selected: Range<Int>
        if wrapped {
            characters.removeSubrange(range.upperBound..<range.upperBound + m)
            characters.removeSubrange(range.lowerBound - m..<range.lowerBound)
            selected = (range.lowerBound - m)..<(range.upperBound - m)
        } else {
            let markCharacters = Array(mark)
            characters.insert(contentsOf: markCharacters, at: range.upperBound)
            characters.insert(contentsOf: markCharacters, at: range.lowerBound)
            selected = (range.lowerBound + m)..<(range.upperBound + m)
        }
        blocks[i].text = String(characters)
        version += 1
        commit()
        let line = Self.sentinel + blocks[i].text
        let lower = line.index(line.startIndex, offsetBy: 1 + selected.lowerBound)
        let upper = line.index(line.startIndex, offsetBy: 1 + selected.upperBound)
        selections[id] = TextSelection(range: lower..<upper)
    }
}

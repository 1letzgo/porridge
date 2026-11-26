import SwiftData
import SwiftUI

/// What the Add sheet starts.
enum AddChoice {
    case note, todo, meeting, link
    case scan, file, audio, plaud
    case template(NoteTemplate)
    case bowl
}

/// "+" of every place: one sheet in place of the "+" fan and the Import menu. Four kinds (Note, To-do, Meeting,
/// Link), Capture (Scan Document, Photo or File, Import Audio, Import from Plaud), From Template (with "Edit") and
/// New Bowl…. "Into:" is the place it was opened from (Today and Inbox: the Inbox; a bowl: that bowl) and can be
/// changed. The choice is handed back; the place starts it once the sheet is gone.
struct AddSheet: View {
    var onPick: (AddChoice, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Where new things go: a bowl (`Projects.key`) or nil for the Inbox.
    @State private var target: String?
    @State private var showTemplates = false
    private let projects: [NoteFolder]
    /// iPad of regular width: shown as a popover at "+". It has no Close (a tap outside closes it) and is as high as
    /// its content, at most `popoverRoom` (it scrolls beyond).
    private let inPopover: Bool
    /// Popover: the lowest point of the window it may reach, in the window's coordinates (the window's height less the
    /// home indicator's safe area), and where its top stands (iPadOS 26 lays a popover from a bar button over the
    /// button, just below the status bar: y 32 in an 834 pt window). Both come from the window alone, never from the
    /// popover's own frame: the system moves the popover when its height changes, so a height taken from its own top
    /// asked for another height on every move (round 7: an endless loop with the largest text sizes in landscape).
    private let popoverBottom: CGFloat
    private let expectedPopoverTop: CGFloat
    /// Popover: the list's whole height with its bar (its content size and insets, not the part in sight), the
    /// largest measured. The list estimates rows it has not laid out yet (smaller than they are), so the height only
    /// grows: the popover first takes its whole room (every row in sight laid out), then the content's height where
    /// that is less. Growing and bounded by the room, it settles after a few steps and cannot swing. Measured anew
    /// (from 0) only when the text size or the templates change.
    @State private var contentHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private var templates: NoteTemplateStore { .shared }

    /// The popover's width, and its highest height while the window's is not known (the rest scrolls).
    static let popoverWidth: CGFloat = 380
    static let defaultMaxPopoverHeight: CGFloat = 640
    /// The popover's margin to `popoverBottom`.
    static let popoverBottomMargin: CGFloat = 12
    /// The least room the popover takes, however small the window.
    static let minPopoverRoom: CGFloat = 300

    init(
        into: String?, projects: [NoteFolder], inPopover: Bool = false, popoverBottom: CGFloat = 0, expectedPopoverTop: CGFloat = 32,
        onPick: @escaping (AddChoice, String?) -> Void
    ) {
        self.projects = projects
        self.inPopover = inPopover
        self.popoverBottom = popoverBottom
        self.expectedPopoverTop = expectedPopoverTop
        self.onPick = onPick
        _target = State(initialValue: into)
    }

    /// The bowls something can be added to: not archived, not shared with me to view only.
    private var writable: [NoteFolder] {
        HomeList.activeProjects(projects).filter { !BowlSharing.shared.isReadOnly($0.id) }
    }

    private var targetName: String {
        target.flatMap { key in projects.first { Projects.key($0) == key }?.name } ?? String(localized: "Inbox")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        Picker("Into", selection: $target) {
                            Label("Inbox", systemImage: "tray").tag(String?.none)
                            ForEach(writable) { project in
                                Label(project.name, systemImage: "folder").tag(Optional(Projects.key(project)))
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Into:")
                                .foregroundStyle(.secondary)
                            Text(targetName)
                                .fontWeight(.semibold)
                                .foregroundStyle(target == nil ? Color.brandSkyText : Color.brandProjectText)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Into: \(targetName)")
                    .accessibilityIdentifier("AddInto")
                    // The four kinds side by side; with the largest text sizes two by two, so their words stay whole.
                    Grid(horizontalSpacing: 10, verticalSpacing: 12) {
                        if typeSize.isAccessibilitySize {
                            GridRow(alignment: .top) {
                                kind("Note", systemImage: "square.and.pencil", tint: .brandSky, choice: .note)
                                kind("To-do", systemImage: "checklist", tint: .brandTask, choice: .todo)
                            }
                            GridRow(alignment: .top) {
                                kind("Meeting", systemImage: "mic.fill", tint: .brandNavy, choice: .meeting)
                                kind("Link", systemImage: "link", tint: .brandLink, choice: .link)
                            }
                        } else {
                            GridRow(alignment: .top) {
                                kind("Note", systemImage: "square.and.pencil", tint: .brandSky, choice: .note)
                                kind("To-do", systemImage: "checklist", tint: .brandTask, choice: .todo)
                                kind("Meeting", systemImage: "mic.fill", tint: .brandNavy, choice: .meeting)
                                kind("Link", systemImage: "link", tint: .brandLink, choice: .link)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                }
                Section("Capture") {
                    if DocumentScanner.isAvailable {
                        row("Scan Document", systemImage: "doc.viewfinder", tint: .brandNavy, choice: .scan)
                    }
                    row("Photo or File", systemImage: "paperclip", tint: .brandNavy, choice: .file)
                    row("Import Audio", systemImage: "waveform", tint: .brandNavy, choice: .audio)
                    row("Import from Plaud", systemImage: "recordingtape", tint: .brandNavy, choice: .plaud)
                }
                Section {
                    if templates.templates.isEmpty {
                        Text("No templates yet. Save an entry as a template from its ⋯ menu, or make one with Edit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(templates.templates) { template in
                        Button { pick(.template(template)) } label: {
                            NoteTemplateRow(template: template) { key in projects.first { Projects.key($0) == key }?.name }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("AddTemplate-\(template.name)")
                    }
                } header: {
                    HStack {
                        Text("From Template")
                        Spacer()
                        Button("Edit") { showTemplates = true }
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                    }
                }
                Section {
                    row("New Bowl…", systemImage: "folder.badge.plus", tint: .brandProject, choice: .bowl)
                }
            }
            .listStyle(.insetGrouped)
            // Popover: the sections closer together (the whole sheet fits the 11-inch iPad's landscape window).
            .listSectionSpacing(inPopover ? .compact : .default)
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inPopover {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            // The list's first content sizes are estimates (44 pt a row) until its rows are laid out, smaller than
            // the rows are: taken as they came, the popover shrank to them and cut a row it had room for. The
            // largest measured height counts (`contentHeight`); the content size does not depend on the popover's
            // height (its width is fixed), only on which rows are laid out yet. The list's own bottom margin ends it.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                if inPopover, height > contentHeight + 0.5 { contentHeight = height }
            }
            .sheet(isPresented: $showTemplates) { NoteTemplatesView() }
        }
        .modifier(PopoverSize(active: inPopover, height: Self.popoverHeight(content: contentHeight, room: popoverRoom)))
        .presentationDetents([.medium, .large])
        // Measured anew where the content's height changes from outside: rows of another height, other templates.
        .onChange(of: typeSize) { if inPopover { contentHeight = 0 } }
        .onChange(of: templates.templates.map(\.id)) { if inPopover { contentHeight = 0 } }
    }

    /// The popover's room: from where iPadOS puts its top down to `popoverBottom` less a margin, from the window alone.
    /// Asking for more made the system move and cut the popover itself (it ended in a card, without a margin).
    private var popoverRoom: CGFloat {
        guard popoverBottom > 0 else { return Self.defaultMaxPopoverHeight }
        return Self.popoverRoom(bottom: popoverBottom, top: expectedPopoverTop)
    }

    /// The popover's room in a window: from `top` down to `bottom` less the margin, at least `minPopoverRoom`.
    static func popoverRoom(bottom: CGFloat, top: CGFloat) -> CGFloat {
        max(minPopoverRoom, (bottom - top - popoverBottomMargin).rounded(.down))
    }

    /// The popover's height: the content's where it fits, else its whole room, where the list scrolls (the list's own
    /// bottom margin ends its content). Until the content is measured (0) the whole room, so every row in sight is laid
    /// out and measured. Nothing else enters it: no row's place, nothing of the popover's own frame, so a height it
    /// gives never asks for another one (applied to its own result it gives that result again).
    static func popoverHeight(content: CGFloat, room: CGFloat) -> CGFloat {
        guard content > 0 else { return room }
        return min(content.rounded(.up), room)
    }

    /// Popover: a fixed width and `height`.
    private struct PopoverSize: ViewModifier {
        let active: Bool
        let height: CGFloat

        func body(content: Content) -> some View {
            if active {
                content
                    .frame(width: AddSheet.popoverWidth, height: height)
                    .presentationCompactAdaptation(.popover)
            } else {
                content
            }
        }
    }

    private func pick(_ choice: AddChoice) {
        onPick(choice, target)
    }

    /// One of the four kinds: a tile with its symbol in its color.
    private func kind(_ title: LocalizedStringKey, systemImage: String, tint: Color, choice: AddChoice) -> some View {
        Button { pick(choice) } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint.readable)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Every tile's word at one size: shrunk to fit one by one, "To-do" stood smaller and higher than
                // "Note" two by two. Two by two (the largest sizes) the words grow up to AX3, which fits "Meeting"
                // in half the row; four across they keep the shrinking for the narrow phone.
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.6)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, tint: Color, choice: AddChoice) -> some View {
        Button { pick(choice) } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint.readable)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

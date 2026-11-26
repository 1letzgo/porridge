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
    /// its content, up to `maxPopoverHeight` (what the window leaves below "+"), scrolling beyond.
    private let inPopover: Bool
    private let maxPopoverHeight: CGFloat
    /// The list's whole height with its bar (popover only), measured. Until then (and while rows below the popover's
    /// edge are only estimated by the list) the popover takes its highest height, so every row that fits is laid out
    /// and measured.
    @State private var contentHeight: CGFloat = 0
    /// Popover: where each row ends in the window, measured while the list is not scrolled (less `listTop`: from the
    /// top of the list's frame). Where the
    /// content is higher than the window leaves, the popover ends at the last row's end that fits (no row cut).
    @State private var rowEnds: [String: CGFloat] = [:]
    /// Popover: the list's top in the window and how far it is scrolled from its start (rows are measured at its start).
    @State private var listTop: CGFloat = 0
    @State private var scrolled: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private var templates: NoteTemplateStore { .shared }

    /// The popover's width, and its highest height while the window's is not known (the rest scrolls).
    static let popoverWidth: CGFloat = 380
    static let defaultMaxPopoverHeight: CGFloat = 640

    init(
        into: String?, projects: [NoteFolder], inPopover: Bool = false, maxPopoverHeight: CGFloat = AddSheet.defaultMaxPopoverHeight,
        onPick: @escaping (AddChoice, String?) -> Void
    ) {
        self.projects = projects
        self.inPopover = inPopover
        self.maxPopoverHeight = maxPopoverHeight
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
                    .rowEnd("into", active: inPopover) { recordRowEnd("into", at: $0) }
                    // The four kinds side by side; with the largest text sizes two by two, so their words stay whole.
                    Grid(horizontalSpacing: 10, verticalSpacing: 12) {
                        if typeSize.isAccessibilitySize {
                            GridRow {
                                kind("Note", systemImage: "square.and.pencil", tint: .brandSky, choice: .note)
                                kind("To-do", systemImage: "checklist", tint: .brandTask, choice: .todo)
                            }
                            GridRow {
                                kind("Meeting", systemImage: "mic.fill", tint: .brandNavy, choice: .meeting)
                                kind("Link", systemImage: "link", tint: .brandLink, choice: .link)
                            }
                        } else {
                            GridRow {
                                kind("Note", systemImage: "square.and.pencil", tint: .brandSky, choice: .note)
                                kind("To-do", systemImage: "checklist", tint: .brandTask, choice: .todo)
                                kind("Meeting", systemImage: "mic.fill", tint: .brandNavy, choice: .meeting)
                                kind("Link", systemImage: "link", tint: .brandLink, choice: .link)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    .rowEnd("kinds", active: inPopover) { recordRowEnd("kinds", at: $0) }
                }
                Section("Capture") {
                    if DocumentScanner.isAvailable {
                        row("Scan Document", systemImage: "doc.viewfinder", tint: .brandNavy, choice: .scan)
                            .rowEnd("scan", active: inPopover) { recordRowEnd("scan", at: $0) }
                    }
                    row("Photo or File", systemImage: "paperclip", tint: .brandNavy, choice: .file)
                        .rowEnd("file", active: inPopover) { recordRowEnd("file", at: $0) }
                    row("Import Audio", systemImage: "waveform", tint: .brandNavy, choice: .audio)
                        .rowEnd("audio", active: inPopover) { recordRowEnd("audio", at: $0) }
                    row("Import from Plaud", systemImage: "recordingtape", tint: .brandNavy, choice: .plaud)
                        .rowEnd("plaud", active: inPopover) { recordRowEnd("plaud", at: $0) }
                }
                Section {
                    if templates.templates.isEmpty {
                        Text("No templates yet. Save an entry as a template from its ⋯ menu, or make one with Edit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .rowEnd("noTemplates", active: inPopover) { recordRowEnd("noTemplates", at: $0) }
                    }
                    ForEach(templates.templates) { template in
                        Button { pick(.template(template)) } label: {
                            NoteTemplateRow(template: template) { key in projects.first { Projects.key($0) == key }?.name }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("AddTemplate-\(template.name)")
                        .rowEnd("template-\(template.id)", active: inPopover) { recordRowEnd("template-\(template.id)", at: $0) }
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
                        .rowEnd("bowl", active: inPopover) { recordRowEnd("bowl", at: $0) }
                }
            }
            .listStyle(.insetGrouped)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { listTop = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrolled = offset
            }
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
            // largest measured height counts; the popover starts at its highest height, so every row that fits is
            // laid out and measured, and it ends with the list's own bottom margin.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                if inPopover { contentHeight = max(contentHeight, height) }
            }
            .sheet(isPresented: $showTemplates) { NoteTemplatesView() }
        }
        .modifier(PopoverSize(active: inPopover, height: popoverHeight))
        .presentationDetents([.medium, .large])
    }

    /// The popover's height: the content's where it fits (until measured, the highest height, so every row that fits
    /// is laid out and measured); where it does not, the end of the last row that fits and the list's margin below it,
    /// so it ends at a row's edge and the rest scrolls.
    private var popoverHeight: CGFloat {
        guard contentHeight > 0 else { return maxPopoverHeight }
        let whole = contentHeight.rounded(.up)
        if whole <= maxPopoverHeight { return whole }
        let margin: CGFloat = 16
        let fitting = rowEnds.values.map { $0 - listTop }.filter { $0 > 0 && $0 + margin <= maxPopoverHeight }.max()
        return fitting.map { ($0 + margin).rounded(.up) } ?? maxPopoverHeight
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

    /// Only at the list's start (the popover opens there): scrolled, a row's place says nothing of the popover.
    private func recordRowEnd(_ id: String, at bottom: CGFloat) {
        guard inPopover, abs(scrolled) < 0.5 else { return }
        rowEnds[id] = bottom
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
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
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

private extension View {
    /// A row of the Add popover reports where it ends in the window (its content's bottom; the cell's own inset
    /// follows). Reported by each row itself: a list's rows hand no preferences up to the list.
    @ViewBuilder
    func rowEnd(_ id: String, active: Bool, _ report: @escaping (CGFloat) -> Void) -> some View {
        if active {
            onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { report($0) }
        } else {
            self
        }
    }
}

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
                    HStack(spacing: 10) {
                        kind("Note", systemImage: "square.and.pencil", tint: .brandSky, choice: .note)
                        kind("To-do", systemImage: "checklist", tint: .brandTask, choice: .todo)
                        kind("Meeting", systemImage: "mic.fill", tint: .brandNavy, choice: .meeting)
                        kind("Link", systemImage: "link", tint: .brandLink, choice: .link)
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
        .modifier(PopoverSize(active: inPopover, contentHeight: contentHeight, maxHeight: maxPopoverHeight))
        .presentationDetents([.medium, .large])
    }

    /// Popover: a fixed width and the content's height (until measured, and beyond the highest height, that height).
    private struct PopoverSize: ViewModifier {
        let active: Bool
        let contentHeight: CGFloat
        let maxHeight: CGFloat

        func body(content: Content) -> some View {
            if active {
                content
                    .frame(
                        width: AddSheet.popoverWidth,
                        height: contentHeight > 0 ? min(contentHeight.rounded(.up), maxHeight) : maxHeight
                    )
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
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

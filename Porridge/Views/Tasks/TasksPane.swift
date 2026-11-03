import SwiftData
import SwiftUI

/// The tasks as sections of a longer list: new ones to look at first, then open, then the ones done (folded),
/// each with the note it comes from. Ticking here ticks the line in the summary too.
struct TaskSections: View {
    enum Part {
        /// New, Mine and General.
        case open
        case done
    }

    let items: [ActionItem]
    let notes: [UUID: Note]
    let part: Part
    /// How many open tasks to show, from the top down.
    var limit = Int.max
    /// Nothing above: the first section sits right under the bar.
    var isFirst = false
    /// Opens the note of a task.
    var onOpen: (UUID) -> Void
    /// The task open in the detail column, marked in the list.
    var selectedID: UUID?
    /// Opens a task on its own page.
    var onEdit: (ActionItem) -> Void

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.myNameKey) private var myName = ""
    @AppStorage(AppSettings.myVoiceNameKey) private var myVoiceName = ""
    @State private var showDone = false

    /// Newest note first, in the order of the summary.
    private var tasks: [(item: ActionItem, note: Note?)] {
        items
            .map { item -> (item: ActionItem, note: Note?) in (item, item.noteID.flatMap { notes[$0] }) }
            .sorted { a, b in
                let dateA = a.note?.createdAt ?? a.item.createdAt
                let dateB = b.note?.createdAt ?? b.item.createdAt
                if dateA != dateB { return dateA > dateB }
                return a.item.order < b.item.order
            }
    }

    var body: some View {
        switch part {
        case .open: openSections
        case .done: doneSection
        }
    }

    @ViewBuilder private var openSections: some View {
        let all = tasks
        let new = all.filter { $0.item.needsReview }
        let open = all.filter { !$0.item.isDone && !$0.item.needsReview }
        let names = AppSettings.myNames(from: myName, voice: myVoiceName)
        let mine = open.filter { ActionItems.isMine($0.item, note: $0.note, names: names) }
        let general = open.filter { !ActionItems.isMine($0.item, note: $0.note, names: names) }
        let shownNew = new.prefix(limit)
        let shownMine = mine.prefix(limit - shownNew.count)
        let shownGeneral = general.prefix(limit - shownNew.count - shownMine.count)
        if !shownNew.isEmpty {
            Section { ForEach(shownNew, id: \.item.id) { row($0.item, note: $0.note) } } header: {
                header("New", count: new.count, isFirst: isFirst)
                    .overlay(alignment: .bottomTrailing) {
                        Button("Accept All") {
                            withAnimation(.snappy) { ActionItems.accept(new.map(\.item), in: context) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandTask)
                        .buttonStyle(.plain)
                        .padding(.bottom, 7)
                    }
            }
        }
        if !shownMine.isEmpty {
            Section { ForEach(shownMine, id: \.item.id) { row($0.item, note: $0.note) } } header: {
                header("Mine", count: mine.count, isFirst: isFirst && new.isEmpty)
            }
        }
        if !shownGeneral.isEmpty {
            Section { ForEach(shownGeneral, id: \.item.id) { row($0.item, note: $0.note) } } header: {
                header("General", count: general.count, isFirst: isFirst && new.isEmpty && mine.isEmpty)
            }
        }
    }

    @ViewBuilder private var doneSection: some View {
        let done = tasks.filter { $0.item.isDone }
        if !done.isEmpty {
            Section {
                if showDone {
                    ForEach(done, id: \.item.id) { row($0.item, note: $0.note) }
                }
            } header: {
                ListHeaderButton(title: "Done", count: done.count, tint: .brandTask, isFirst: isFirst, isOpen: showDone) {
                    withAnimation(.snappy) { showDone.toggle() }
                }
            }
        }
    }

    private func header(_ title: String, count: Int, isFirst: Bool) -> some View {
        ListHeader(title: title, count: count, tint: .brandTask, isFirst: isFirst)
    }

    private func row(_ item: ActionItem, note: Note?) -> some View {
        TaskRow(item: item, note: note, selectedID: selectedID, onOpen: onOpen, onEdit: onEdit)
    }
}

/// One task: tick box, title, details, owner and note; tapped it opens on its own page. Used by the task list
/// and the projects.
struct TaskRow: View {
    let item: ActionItem
    let note: Note?
    var selectedID: UUID?
    var onOpen: (UUID) -> Void
    var onEdit: (ActionItem) -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.snappy) { ActionItems.setDone(item, !item.isDone, note: note, in: context) }
            } label: {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(Color.brandTask)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as Open" : "Mark as Done")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text.isEmpty ? "Untitled Task" : item.text)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone || item.text.isEmpty ? .secondary : .primary)
                let details = NoteText.plainLines(item.details).joined(separator: " ")
                if !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if item.isArchived {
                        Image(systemName: "archivebox")
                            .accessibilityLabel("Archived")
                    }
                    if let owner = item.owner {
                        Text(owner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandNavy)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .chunkyPill(fill: .brandTask)
                    }
                    if let note {
                        Text(note.displayTitle)
                            .lineLimit(1)
                        Text("·")
                    }
                    Text((note?.createdAt ?? item.createdAt).formatted(.dateTime.day().month(.abbreviated)))
                        .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onEdit(item) }
            if item.needsReview { reviewButtons(item) }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            selectedID == item.id ? Color.brandTask.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, -6)
        .cardListRow()
        .swipeActions(edge: .leading) {
            if item.needsReview {
                Button { withAnimation(.snappy) { ActionItems.accept([item], in: context) } } label: { Label("Accept", systemImage: "checkmark") }
                    .tint(.brandTask)
            }
        }
        .swipeActions(edge: .trailing) {
            if item.needsReview {
                Button(role: .destructive) { withAnimation(.snappy) { ActionItems.dismiss(item, in: context) } } label: { Label("Dismiss", systemImage: "xmark") }
            } else {
                Button(role: .destructive) { ActionItems.delete(item, in: context) } label: { Label("Delete", systemImage: "trash") }
                archiveButton.tint(.brandNavy)
            }
        }
        .contextMenu {
            if item.needsReview {
                Button { ActionItems.accept([item], in: context) } label: { Label("Accept", systemImage: "checkmark") }
                Button { ActionItems.dismiss(item, in: context) } label: { Label("Dismiss", systemImage: "xmark") }
                Divider()
            }
            Button { onEdit(item) } label: { Label("Open Task", systemImage: "checklist") }
            if let note {
                Button { onOpen(note.id) } label: { Label("Open Note", systemImage: "note.text") }
            }
            ProjectMenu(assigned: item.projectIDs, inherited: note?.projectIDs ?? []) { Projects.toggle($0, on: item, in: context) }
            if !item.needsReview { archiveButton }
            Button { Clipboard.copy(item.line) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { ActionItems.delete(item, in: context) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var archiveButton: some View {
        Button {
            withAnimation(.snappy) { Archive.set(!item.isArchived, item, in: context) }
        } label: {
            Label(item.isArchived ? "Unarchive" : "Archive", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
    }

    /// Take a new task on or drop it, right in its row.
    private func reviewButtons(_ item: ActionItem) -> some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy) { ActionItems.dismiss(item, in: context) } } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
            Button { withAnimation(.snappy) { ActionItems.accept([item], in: context) } } label: {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.brandTask)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Accept")
        }
        .buttonStyle(.plain)
    }
}

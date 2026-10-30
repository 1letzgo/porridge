import SwiftData
import SwiftUI

/// All tasks from the summaries in one list: new ones to look at first, then open, then the ones done, each
/// with the note it comes from. Ticking here ticks the line in the summary too.
struct TasksPane: View {
    let items: [ActionItem]
    let notes: [Note]
    /// Only the tasks out of notes with this tag (lowercased), when set.
    var tag: String?
    /// Opens the note of a task.
    var onOpen: (UUID) -> Void
    /// The task open in the detail column, marked in the list.
    var selectedID: UUID?
    /// Opens a task on its own page.
    var onEdit: (ActionItem) -> Void

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.myNameKey) private var myName = ""
    @State private var showDone = false

    private var byID: [UUID: Note] {
        Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tasks of notes that still exist and tasks typed by hand, newest first, in the order of the summary.
    private var tasks: [(item: ActionItem, note: Note?)] {
        let notes = byID
        return items.compactMap { item -> (ActionItem, Note?, Date)? in
            guard item.kind == .task, item.review != .dismissed else { return nil }
            // A task whose note is gone stays as a task of its own.
            guard let id = item.noteID, let note = notes[id] else { return tag == nil ? (item, nil, item.createdAt) : nil }
            guard !note.isDeleted, !note.isLink else { return nil }
            if let tag, !note.tags.contains(where: { $0.lowercased() == tag }) { return nil }
            return (item, note, note.createdAt)
        }
        .sorted { a, b in
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.order < b.0.order
        }
        .map { (item: $0.0, note: $0.1) }
    }

    var body: some View {
        let all = tasks
        let new = all.filter { $0.item.needsReview }
        let open = all.filter { !$0.item.isDone && !$0.item.needsReview }
        let names = AppSettings.myNames(from: myName)
        let mine = open.filter { ActionItems.isMine($0.item, note: $0.note, names: names) }
        let general = open.filter { !ActionItems.isMine($0.item, note: $0.note, names: names) }
        let done = all.filter { $0.item.isDone }
        List {
            if !new.isEmpty {
                Section { ForEach(new, id: \.item.id) { row($0.item, note: $0.note) } } header: {
                    HStack(alignment: .firstTextBaseline) {
                        header("New", count: new.count)
                        Button("Accept All") {
                            withAnimation(.snappy) { ActionItems.accept(new.map(\.item), in: context) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandTask)
                        .buttonStyle(.plain)
                    }
                }
            }
            if !mine.isEmpty {
                Section { ForEach(mine, id: \.item.id) { row($0.item, note: $0.note) } } header: { header("Mine", count: mine.count) }
            }
            if !general.isEmpty {
                Section { ForEach(general, id: \.item.id) { row($0.item, note: $0.note) } } header: { header("General", count: general.count) }
            }
            if !done.isEmpty {
                Section {
                    if showDone {
                        ForEach(done, id: \.item.id) { row($0.item, note: $0.note) }
                    }
                } header: {
                    Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                        HStack {
                            header("Done", count: done.count)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showDone ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .cardList()
        .overlay {
            if all.isEmpty {
                EmptyStateView(
                    title: "No Tasks Yet",
                    message: "Tasks come from the summaries of your meetings and notes, or you add one with the plus button.",
                    systemImage: "checklist"
                )
            }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.brandTask)
            Rectangle().fill(Look.hairline).frame(height: 0.5)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
        .textCase(nil)
    }

    private func row(_ item: ActionItem, note: Note?) -> some View {
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
            Button { Clipboard.copy(item.line) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { ActionItems.delete(item, in: context) } label: { Label("Delete", systemImage: "trash") }
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

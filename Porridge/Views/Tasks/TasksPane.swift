import SwiftData
import SwiftUI

/// All tasks from the summaries in one list: open first, then the ones done, each with the note it comes
/// from. Ticking here ticks the line in the summary too.
struct TasksPane: View {
    let items: [ActionItem]
    let notes: [Note]
    /// Opens the note of a task.
    var onOpen: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @State private var showDone = false

    private var byID: [UUID: Note] {
        Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tasks of notes that still exist and tasks typed by hand, newest first, in the order of the summary.
    private var tasks: [(item: ActionItem, note: Note?)] {
        let notes = byID
        return items.compactMap { item -> (ActionItem, Note?, Date)? in
            guard item.kind == .task else { return nil }
            guard let id = item.noteID else { return (item, nil, item.createdAt) }
            guard let note = notes[id], !note.isDeleted, !note.isLink else { return nil }
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
        let open = all.filter { !$0.item.isDone }
        let done = all.filter { $0.item.isDone }
        List {
            if !open.isEmpty {
                Section { ForEach(open, id: \.item.id) { row($0.item, note: $0.note) } } header: { header("Open", count: open.count) }
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
            .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(Color.brandSky)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as Open" : "Mark as Done")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let owner = item.owner {
                        Text(owner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandNavy)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .chunkyPill(fill: .brandSky)
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
            .onTapGesture { if let note { onOpen(note.id) } }
        }
        .cardListRow()
        .swipeActions(edge: .trailing) {
            if note == nil {
                Button(role: .destructive) { ActionItems.delete(item, in: context) } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            if let note {
                Button { onOpen(note.id) } label: { Label("Open Note", systemImage: "note.text") }
            }
            Button { Clipboard.copy(item.line) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if note == nil {
                Divider()
                Button(role: .destructive) { ActionItems.delete(item, in: context) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

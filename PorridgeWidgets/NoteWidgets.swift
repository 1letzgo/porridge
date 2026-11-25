import AppIntents
import SwiftUI
import WidgetKit

// The widgets that show the notes: the to-dos due today, the inbox, and their counts on the Lock Screen. They read
// the copy the app keeps in the app group (`WidgetSnapshot`); a box ticked here is queued for the app
// (`CompleteTodoIntent`).

// MARK: - Timeline

struct NotesEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// Shared into the app or added by a shortcut, not yet taken in by the app.
    var waitingShares = 0
    /// No copy written yet: the app has not run since the widgets came.
    var isEmptyStore = false

    var inboxCount: Int { snapshot.inboxCount + waitingShares }
}

struct NotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        let entry = load(at: .now)
        completion(context.isPreview && entry.isEmptyStore ? .sample : entry)
    }

    /// One entry now and one at midnight: what is due today and what is overdue moves on with the day.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        let now = Date.now
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        completion(Timeline(entries: [now, midnight].map(load(at:)), policy: .atEnd))
    }

    private func load(at date: Date) -> NotesEntry {
        guard let stored = WidgetStore.snapshot() else {
            return NotesEntry(date: date, snapshot: WidgetSnapshot(), waitingShares: ShareInbox.pending().count, isEmptyStore: true)
        }
        return NotesEntry(
            date: date, snapshot: stored.applying(WidgetStore.pendingCompletions()), waitingShares: ShareInbox.pending().count
        )
    }
}

extension NotesEntry {
    /// For the widget gallery before the app has written anything.
    static var sample: NotesEntry {
        let today = WidgetSnapshot.dayKey(.now)
        let yesterday = WidgetSnapshot.dayKey(.now.addingTimeInterval(-86_400))
        return NotesEntry(date: .now, snapshot: WidgetSnapshot(
            inboxCount: 4,
            inbox: [
                .init(id: UUID().uuidString, title: "Ideas for the offsite", symbol: "text.alignleft"),
                .init(id: UUID().uuidString, title: "Weekly sync", symbol: "waveform"),
                .init(id: UUID().uuidString, title: "github.com", symbol: "link"),
                .init(id: UUID().uuidString, title: "Receipt", symbol: "doc.richtext"),
            ],
            openTodoCount: 5,
            todos: [
                .init(id: UUID().uuidString, title: "Send the invoice", due: yesterday),
                .init(id: UUID().uuidString, title: "Call the plumber", due: today),
                .init(id: UUID().uuidString, title: "Water the plants", due: today, isRepeating: true),
            ]
        ))
    }
}

// MARK: - Look

/// The app's colors (the same color sets, light, dark and high contrast).
private enum Palette {
    static let sky = Color("BrandSky")
    static let skyText = Color("BrandSkyText")
    static let task = Color("BrandTask")
    static let taskText = Color("BrandTaskText")
    static let danger = Color("BrandDangerText")
    static let onFill = Color("BrandOnFill")
}

/// The rounded square of the app's list rows (`ThingsRowIcon`): a wash of the color, its border, the symbol.
private struct RowIcon: View {
    let systemImage: String
    let tint: Color
    let text: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(text)
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size / 4, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1.2))
    }
}

/// The box of a to-do, as in the app (`TodoCheckbox`): a green square.
private struct TodoBox: View {
    var isReadOnly = false
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(Palette.task.opacity(isReadOnly ? 0.05 : 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                    .strokeBorder(Palette.task.opacity(isReadOnly ? 0.35 : 0.75), lineWidth: 1.5)
            )
            .widgetAccentable()
            .frame(width: size, height: size)
    }
}

/// "New Note": a round button with a wash of sky, the plus in the readable sky.
private struct CaptureButton: View {
    var body: some View {
        Button(intent: NewNoteIntent()) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.skyText)
                .widgetAccentable()
                .frame(width: 30, height: 30)
                .background(Palette.sky.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Note")
    }
}

private struct WidgetHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let text: Color
    let detail: Text?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(systemImage: systemImage, tint: tint, text: text)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if let detail {
                    detail
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
    }
}

// MARK: - To-dos

struct TodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.todos, provider: NotesProvider()) { entry in
            TodosWidgetView(entry: entry)
        }
        .configurationDisplayName("To-dos")
        .description("Your to-dos due today and overdue. Tick them off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct TodosWidgetView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family

    private var limit: Int {
        switch family {
        case .systemLarge: 9
        default: 3
        }
    }

    var body: some View {
        let todos = entry.snapshot.dueToday(now: entry.date)
        let overdue = entry.snapshot.overdueCount(now: entry.date)
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            WidgetHeader(
                title: String(localized: "Today"), systemImage: "checklist", tint: Palette.task, text: Palette.taskText,
                detail: family == .systemSmall ? nil : detail(due: todos.count, overdue: overdue)
            ) {
                if family == .systemSmall, !todos.isEmpty {
                    Text("\(todos.count)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(overdue > 0 ? Palette.danger : .secondary)
                }
            }
            if todos.isEmpty {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Palette.taskText)
                        .widgetAccentable()
                    Text(entry.isEmptyStore ? "Open Porridge once to see your to-dos." : "Nothing due today.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 8) {
                    ForEach(todos.prefix(limit)) { todo in
                        TodoRow(todo: todo, now: entry.date, isCompact: family == .systemSmall)
                    }
                }
                Spacer(minLength: 0)
                if todos.count > limit {
                    Text("\(todos.count - limit) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(QuickAction.openTodos.url)
    }

    private func detail(due: Int, overdue: Int) -> Text {
        if due == 0 { return Text("\(entry.snapshot.openTodoCount) open") }
        let today = Text(due == 1 ? "1 to do" : "\(due) to do")
        guard overdue > 0 else { return today }
        return Text("\(today) · \(Text("\(overdue) overdue").foregroundStyle(Palette.danger).fontWeight(.semibold))")
    }
}

private struct TodoRow: View {
    let todo: WidgetSnapshot.Todo
    let now: Date
    /// The small widget: one line, the title red when overdue; it opens as a whole (no links in it).
    let isCompact: Bool

    var body: some View {
        let overdue = WidgetSnapshot.isOverdue(todo, now: now)
        HStack(spacing: 9) {
            if todo.isReadOnly {
                TodoBox(isReadOnly: true)
                    .accessibilityLabel("View only")
            } else {
                Button(intent: CompleteTodoIntent(todoID: todo.id, due: todo.due)) {
                    TodoBox()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(todo.title) as Done")
            }
            if isCompact {
                Text(todo.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(overdue ? Palette.danger : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else if let id = UUID(uuidString: todo.id) {
                Link(destination: QuickAction.openNote(id).url) { label(overdue: overdue) }
            } else {
                label(overdue: overdue)
            }
        }
    }

    private func label(overdue: Bool) -> some View {
        HStack(spacing: 6) {
            Text(todo.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if todo.isRepeating {
                Image(systemName: "repeat")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if overdue, let due = todo.due {
                Text(WidgetSnapshot.dueLabel(due, now: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Inbox

struct InboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.inbox, provider: NotesProvider()) { entry in
            InboxWidgetView(entry: entry)
        }
        .configurationDisplayName("Inbox")
        .description("What waits in your inbox, and a new note in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct InboxWidgetView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                small
            } else {
                list
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(QuickAction.openInbox.url)
    }

    private var waitingText: Text {
        entry.inboxCount == 0 ? Text("Nothing waiting") : Text("\(entry.inboxCount) waiting")
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                RowIcon(systemImage: "tray.fill", tint: Palette.sky, text: Palette.skyText, size: 30)
                Spacer()
                CaptureButton()
            }
            Spacer(minLength: 0)
            Text("\(entry.inboxCount)")
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(entry.inboxCount == 0 ? "Nothing waiting" : "Inbox")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        let shown = entry.snapshot.inbox.prefix(family == .systemLarge ? 8 : 3)
        return VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: String(localized: "Inbox"), systemImage: "tray.fill", tint: Palette.sky, text: Palette.skyText, detail: waitingText) {
                CaptureButton()
            }
            if shown.isEmpty {
                Spacer(minLength: 0)
                Text(entry.isEmptyStore ? "Open Porridge once to see your inbox." : "All filed. New notes wait here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { item in
                        if let id = UUID(uuidString: item.id) {
                            Link(destination: QuickAction.openNote(id).url) { InboxRow(item: item) }
                        } else {
                            InboxRow(item: item)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct InboxRow: View {
    let item: WidgetSnapshot.Entry

    var body: some View {
        HStack(spacing: 9) {
            RowIcon(systemImage: item.symbol, tint: tint, text: text, size: 20)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// To-dos green as in the app, everything else sky.
    private var tint: Color { item.symbol == "checklist" ? Palette.task : Palette.sky }
    private var text: Color { item.symbol == "checklist" ? Palette.taskText : Palette.skyText }
}

// MARK: - Lock Screen

struct InboxCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.inboxCount, provider: NotesProvider()) { entry in
            InboxCountView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(QuickAction.openInbox.url)
        }
        .configurationDisplayName("Inbox")
        .description("How much waits in your inbox.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct InboxCountView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(entry.inboxCount) in Inbox", systemImage: "tray.fill")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Inbox", systemImage: "tray.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text(entry.inboxCount == 0 ? "Nothing waiting" : "\(entry.inboxCount) waiting")
                    .font(.subheadline)
                if let first = entry.snapshot.inbox.first {
                    Text(first.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            CircularCount(systemImage: "tray.fill", count: entry.inboxCount)
                .accessibilityLabel("Inbox, \(entry.inboxCount) waiting")
        }
    }
}

struct TodoCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.todoCount, provider: NotesProvider()) { entry in
            TodoCountView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(QuickAction.openTodos.url)
        }
        .configurationDisplayName("Open To-dos")
        .description("How many to-dos are open, and how many overdue.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct TodoCountView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let open = entry.snapshot.openTodoCount
        let overdue = entry.snapshot.overdueCount(now: entry.date)
        switch family {
        case .accessoryInline:
            Label("\(open) open to-dos", systemImage: "checklist")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("To-dos", systemImage: "checklist")
                    .font(.headline)
                    .widgetAccentable()
                Text(overdue > 0 ? "\(open) open · \(overdue) overdue" : open == 0 ? "Nothing open" : "\(open) open")
                    .font(.subheadline)
                if let first = entry.snapshot.dueToday(now: entry.date).first {
                    Text(first.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            CircularCount(systemImage: "checklist", count: open)
                .accessibilityLabel("\(open) open to-dos")
        }
    }
}

struct NewNoteAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.newNote, provider: QuickActionsProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
            .accessibilityLabel("New Note")
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(QuickAction.newNote.url)
        }
        .configurationDisplayName("New Note")
        .description("Opens Porridge with a new note.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct CircularCount: View {
    let systemImage: String
    let count: Int

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text("\(count)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

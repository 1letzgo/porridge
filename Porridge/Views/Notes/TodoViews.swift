import SwiftData
import SwiftUI

/// The box of a to-do: in a list row it takes the place of the kind's icon (as high as the row's two lines), in
/// its page it stands before the title. Green squares are tasks (`DESIGN.md`); circles are the subtasks in the text.
struct TodoCheckbox: View {
    let isDone: Bool
    /// The row's icon size; the page uses a smaller one.
    var size: CGFloat = 44
    var isPinned = false
    let toggle: () -> Void

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = min(size * scale, size * 1.27)
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: side / 4, style: .continuous)
                    .fill(isDone ? Color.brandTask : Color.brandTask.opacity(0.10))
                RoundedRectangle(cornerRadius: side / 4, style: .continuous)
                    .strokeBorder(Color.brandTask.opacity(isDone ? 1 : 0.75), lineWidth: 1.5)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: side * 0.42, weight: .bold))
                        // Symbols on a full fill of green are navy.
                        .foregroundStyle(Color.brandOnFill)
                }
            }
            .frame(width: side, height: side)
            // 44 pt to tap, however small the box is drawn.
            .contentShape(Rectangle().inset(by: -max(0, 44 - side) / 2))
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.brandOnNavy)
                        .frame(width: 18, height: 18)
                        .background(Color.brandNavy, in: Circle())
                        .overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("To-do")
        .accessibilityValue(isDone ? "Done" : "Not Done")
        .accessibilityAddTraits(.isToggle)
        .sensoryFeedback(.success, trigger: isDone) { _, done in done }
    }
}

/// "2/5" with a checklist symbol: how many subtasks of a to-do are ticked.
struct TodoProgressLabel: View {
    let progress: Todos.Progress

    var body: some View {
        if progress.total > 0 {
            HStack(spacing: 3) {
                // Circles, like the subtasks in the text; `checklist` is the symbol of the kind.
                Image(systemName: "checkmark.circle")
                Text(progress.label).monospacedDigit()
            }
                .foregroundStyle(progress.isComplete ? Color.brandTaskText : .secondary)
                .fixedSize()
                .accessibilityLabel("\(progress.done) of \(progress.total) subtasks done")
        }
    }
}

/// The way from a to-do back to the note whose summary it was taken from.
struct TodoSourcePill: View {
    let source: Note

    @Environment(\.openNote) private var openNote

    var body: some View {
        Button { openNote(source.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: source.kindSymbol)
                Text(source.displayTitle).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brandNavy)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.brandNavy.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("From \(source.displayTitle)")
    }
}

// MARK: - Due day

extension Todos {
    /// The color of a due day: red when an open to-do is late, green for today, otherwise quiet. A done to-do
    /// is never marked.
    static func dueTint(_ note: Note) -> Color {
        guard let due = note.todoDue, !note.isDone else { return .secondary }
        switch dueStatus(due) {
        case .overdue?: return .brandDangerText
        case .today?: return .brandTaskText
        default: return .secondary
        }
    }
}

/// The due day in a list row: a calendar symbol and "Today", "Fri", "12 Dec".
struct TodoDueLabel: View {
    let note: Note

    var body: some View {
        if let due = note.todoDue {
            let label = Todos.dueLabel(due)
            HStack(spacing: 3) {
                Image(systemName: note.isOverdue ? "calendar.badge.exclamationmark" : "calendar")
                Text(label)
                if note.todoRepeat != nil { Image(systemName: "repeat").imageScale(.small) }
            }
            .foregroundStyle(Todos.dueTint(note))
            .fontWeight(note.isOverdue || Todos.dueStatus(due) == .today && !note.isDone ? .semibold : nil)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((note.isOverdue ? "Overdue, due \(label)" : "Due \(label)") + (note.todoRepeat.map { ", repeats \($0.title)" } ?? ""))
        }
    }
}

/// The choices for a due day, as buttons of a menu: Today, Tomorrow, Next Week, Pick Date…, and Clear.
struct DueDateMenuItems: View {
    let note: Note
    /// Opens the date picker.
    let pickDate: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        ForEach(Todos.DueChoice.allCases, id: \.self) { choice in
            Button {
                withAnimation(.snappy) { Todos.setDue(Todos.dueKey(for: choice), note, in: context) }
            } label: {
                Label(choice.title, systemImage: choice.systemImage)
            }
        }
        Button(action: pickDate) { Label("Pick Date…", systemImage: "calendar") }
        RepeatMenu(note: note, custom: pickDate)
        if note.todoDue != nil {
            Divider()
            Button(role: .destructive) {
                withAnimation(.snappy) { Todos.setDue(nil, note, in: context) }
            } label: {
                Label("Clear Due Date", systemImage: "calendar.badge.minus")
            }
        }
    }
}

/// The due day on a to-do's page, in the row of its bowls and tags: a menu with the choices.
struct DueDateChip: View {
    let note: Note
    @Binding var isPicking: Bool

    var body: some View {
        Menu {
            DueDateMenuItems(note: note) { isPicking = true }
        } label: {
            HStack(spacing: 6) {
                if let due = note.todoDue {
                    Image(systemName: note.isOverdue ? "calendar.badge.exclamationmark" : "calendar")
                    Text(Todos.dueLabel(due))
                    if note.todoRepeat != nil { Image(systemName: "repeat").imageScale(.small) }
                } else {
                    Image(systemName: "plus")
                    Text("Due Date")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(note.todoDue == nil ? Color.brandNavy : note.isOverdue ? Color.brandDangerText : Color.brandTaskText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .chunkyPill(fill: note.todoDue == nil ? .gray : note.isOverdue ? .red : .brandTask)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.todoDue.map { "Due \(Todos.dueLabel($0))" + (note.todoRepeat.map { ", repeats \($0.title)" } ?? "") } ?? "Add Due Date")
    }
}

/// How the to-do repeats: Never, Daily, Weekly, Monthly, Yearly, or every so many days (in the date sheet).
/// A repeating to-do moves to its next due day when it is done; there are no reminders.
struct RepeatMenu: View {
    let note: Note
    /// Opens the date sheet, which also sets "Every N Days".
    let custom: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        let current = note.todoRepeat
        Menu {
            Button {
                withAnimation(.snappy) { Todos.setRepeat(nil, note, in: context) }
            } label: {
                if current == nil { Label("Never", systemImage: "checkmark") } else { Text("Never") }
            }
            ForEach(TodoRepeat.presets, id: \.self) { rule in
                Button {
                    withAnimation(.snappy) { Todos.setRepeat(rule, note, in: context) }
                } label: {
                    if rule.sameRule(as: current) { Label(rule.title, systemImage: "checkmark") } else { Text(rule.title) }
                }
            }
            Divider()
            Button(action: custom) {
                if let current, !TodoRepeat.presets.contains(where: { $0.sameRule(as: current) }) {
                    Label(current.title, systemImage: "checkmark")
                } else {
                    Text("Every N Days…")
                }
            }
        } label: {
            Label(current.map { "Repeat: \($0.title)" } ?? String(localized: "Repeat"), systemImage: "repeat")
        }
    }
}

/// The system's calendar to pick a due day, in a sheet.
struct DueDatePickerSheet: View {
    let note: Note

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    /// "never", "day", "week", "month", "year" or "days" (every N days).
    @State private var repeatChoice = "never"
    @State private var everyDays = 2

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Due Date", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.brandTask)
                HStack {
                    Label("Repeat", systemImage: "repeat")
                    Spacer()
                    Picker("Repeat", selection: $repeatChoice) {
                        Text("Never").tag("never")
                        ForEach(TodoRepeat.presets, id: \.self) { Text($0.title).tag($0.unit.rawValue) }
                        Text("Every N Days").tag("days")
                    }
                    .labelsHidden()
                }
                if repeatChoice == "days" {
                    Stepper("Every \(everyDays) days", value: $everyDays, in: 2...365)
                }
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Due Date")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Todos.setDue(Todos.dueKey(day), note, in: context)
                        Todos.setRepeat(chosenRule, note, in: context)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            day = note.todoDue.flatMap { Todos.dueDate($0) } ?? Date()
            if let rule = note.todoRepeat {
                if rule.unit == .day, rule.interval > 1 {
                    repeatChoice = "days"
                    everyDays = rule.interval
                } else if rule.interval == 1 {
                    repeatChoice = rule.unit.rawValue
                } else {
                    // Every 2 weeks and the like (set elsewhere) are shown as days.
                    repeatChoice = "days"
                    everyDays = rule.interval * (rule.unit == .week ? 7 : 1)
                }
            }
        }
    }

    private var chosenRule: TodoRepeat? {
        switch repeatChoice {
        case "days": .everyDays(everyDays)
        case "never": nil
        default:
            // An unchanged rule keeps its interval (every 2 months stays every 2 months).
            if let current = note.todoRepeat, current.unit.rawValue == repeatChoice { current } else { TodoRepeat.Unit(rawValue: repeatChoice).map { TodoRepeat(unit: $0) } }
        }
    }
}

// MARK: - Suggested to-dos

/// The tasks of a summary offered as to-dos, on the page of the meeting (or note): each can be picked and its
/// title changed; one button takes the picked ones on, Dismiss lets them all go. Nothing is made without a tap.
struct SuggestedTodosCard: View {
    let note: Note
    let suggestions: [TaskSuggestion]

    @Environment(\.modelContext) private var context
    @State private var picked: Set<String> = []
    @State private var titles: [String: String] = [:]
    /// The suggestions the picks were made for: new ones (a new summary) get their own preselection.
    @State private var known: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                Text("Suggested To-dos")
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.brandTaskText)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions) { s in row(s) }
            }

            HStack(spacing: 12) {
                Menu {
                    Button { take(asOne: true) } label: {
                        Label("Add as One To-do with Subtasks", systemImage: "checklist")
                    }
                } label: {
                    Text(picked.count == 1 ? "Add 1 To-do" : "Add \(picked.count) To-dos")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color.brandNavy)
                        .background(Color.brandTask.opacity(picked.isEmpty ? 0.1 : 0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } primaryAction: {
                    take(asOne: false)
                }
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("AddSuggestedTodos")

                Button("Dismiss") {
                    withAnimation(.snappy) { TodoSuggestions.dismiss(suggestions, from: note, in: context) }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
        }
        .padding(14)
        .background(Color.brandTask.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.brandTask.opacity(0.35), lineWidth: 1))
        .onAppear(perform: preselect)
        .onChange(of: suggestions.map(\.key)) { preselect() }
    }

    private func row(_ s: TaskSuggestion) -> some View {
        let isOn = picked.contains(s.key)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                if isOn { picked.remove(s.key) } else { picked.insert(s.key) }
            } label: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.brandTaskText : .secondary)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(titles[s.key] ?? s.title))
            .accessibilityValue(isOn ? "Selected" : "Not Selected")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("Suggestion")
            VStack(alignment: .leading, spacing: 2) {
                TextField("To-do", text: Binding(get: { titles[s.key] ?? s.title }, set: { titles[s.key] = $0 }), axis: .vertical)
                    .foregroundStyle(isOn ? .primary : .secondary)
                if s.owner != nil || s.dueDay != nil {
                    HStack(spacing: 8) {
                        if let owner = s.owner {
                            Label(owner, systemImage: "person").labelStyle(.titleAndIcon)
                        }
                        if let due = s.dueDay {
                            Label(Todos.dueLabel(due), systemImage: "calendar").labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Picked at first: the user's own tasks and nobody's, or all when the app does not know the user's name.
    private func preselect() {
        let names = AppSettings.myNames
        for s in suggestions where !known.contains(s.key) {
            known.insert(s.key)
            if names.isEmpty || s.isMine { picked.insert(s.key) }
        }
        picked.formIntersection(Set(suggestions.map(\.key)))
    }

    private func take(asOne: Bool) {
        let chosen = suggestions.filter { picked.contains($0.key) }.map { s -> TaskSuggestion in
            var s = s
            let title = (titles[s.key] ?? s.title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { s.title = title }
            return s
        }
        let rest = suggestions.filter { !picked.contains($0.key) }
        withAnimation(.snappy) {
            TodoSuggestions.take(chosen, dismissing: rest, from: note, asOne: asOne, in: context)
        }
    }
}

/// The to-dos made from a meeting, on its page: ticked right there, opened with a tap.
struct MadeTodosList: View {
    let todos: [Note]

    @Environment(\.modelContext) private var context
    @Environment(\.openNote) private var openNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                Text("To-dos")
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.brandTaskText)
            ForEach(Todos.byDue(todos)) { todo in
                HStack(spacing: 10) {
                    TodoCheckbox(isDone: todo.isDone, size: 22) {
                        withAnimation(.snappy) { Todos.setDone(!todo.isDone, todo, in: context) }
                    }
                    Button { openNote(todo.id) } label: {
                        HStack(spacing: 8) {
                            Text(todo.displayTitle)
                                .strikethrough(todo.isDone, color: .secondary)
                                .foregroundStyle(todo.isDone ? .secondary : .primary)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            TodoDueLabel(note: todo).font(.caption)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

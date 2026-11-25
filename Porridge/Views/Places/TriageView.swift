import SwiftData
import SwiftUI

/// Triage (iPhone): the Inbox one entry at a time, full screen without the tab bar. File (into the suggested bowl;
/// "Other…" picks one), Later, Skip, Delete, and Done for a to-do: the Mac's F, L, J, ⌫ and D. Every step offers the
/// one undo toast; an entry brought back by Undo is in front again. The bar's "Done" ends it.
struct TriageView: View {
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Taken once the entries are there (the Inbox's order at the start).
    @State private var triage: InboxTriage?
    @State private var laterNote: Note?
    @State private var bowlNote: Note?

    var body: some View {
        let current = triage?.current(in: notes)
        VStack(spacing: 0) {
            ChromeBar(title: String(localized: "Triage"), systemImage: "bolt.fill", tint: .brandSky) {
                Button { dismiss() } label: {
                    Text("Done").fontWeight(.semibold).padding(.horizontal, 10)
                }
                .buttonStyle(ChromePillButtonStyle(fill: .brandSky))
                .labelStyle(.titleOnly)
                .accessibilityIdentifier("TriageEnd")
            }
            .padding(.bottom, Look.headerGap)

            if let triage, let current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Entry \(current.index + 1) of \(triage.total) · New")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("TriageCounter")
                        card(current.note)
                            .id(current.note.id)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        buttons(for: current.note)
                        let next = triage.upcoming(in: notes)
                        if !next.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Next")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(next) { note in
                                    HStack(spacing: 10) {
                                        Image(systemName: note.kindSymbol)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22)
                                        Text(note.displayTitle)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.subheadline)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.bottom, 90)
                }
            } else if triage != nil {
                finished
            } else {
                Spacer()
            }
        }
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            UndoToastView().padding(.bottom, 16)
        }
        .animation(.snappy, value: current?.note.id)
        .onAppear {
            if triage == nil { triage = InboxTriage(notes: notes) }
        }
        .sheet(item: $laterNote) { note in LaterSheet(notes: [note]) }
        .sheet(item: $bowlNote) { note in BowlPickerSheet(notes: [note]) }
    }

    // MARK: The entry

    private func card(_ note: Note) -> some View {
        let bowls = projects
        let suggestion = InboxTriage.suggestion(for: note, bowls: bowls)
        let facts = EntryMeta.facts(for: note, context: EntryContext(bowls: bowls))
        let document = note.isDocument ? note.documentInfo.flatMap { $0.isEmpty ? nil : $0 } : nil
        let text = note.summary.map(Self.plain) ?? note.preview
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: note.kindSymbol, tint: tint(note))
                    .accessibilityLabel(note.kindName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.displayTitle)
                        .font(.headline)
                        .lineLimit(3)
                    Text(facts)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.85))
                    // With the largest text sizes six lines would push File, Later and Skip off the screen.
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 6)
            }
            if let document {
                HStack(spacing: 8) {
                    Text(document.line)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.brandNavy.readable)
                        .lineLimit(1)
                    if document.offersPaid {
                        Text(document.paid ? "Paid" : "Unpaid")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(document.paid ? Color.brandTaskText : Color.brandDangerText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((document.paid ? Color.brandTask : Color.red).opacity(0.12), in: Capsule())
                    }
                }
            }
            if note.isTodo, let due = note.todoDue {
                Label("Due \(Todos.dueLabel(due))", systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.brandProject.readable)
                if let suggestion {
                    Text("Suggested bowl: \(suggestion.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandProject.readable)
                        .lineLimit(1)
                } else {
                    Text("No bowl suggested")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Other…") { bowlNote = note }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandNavy.readable)
                    .accessibilityIdentifier("TriageOther")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
        .padding(.horizontal, 14)
    }

    private func tint(_ note: Note) -> Color {
        note.isTodo ? .brandTask : note.isLink ? .brandLink : (note.isRecording || note.isStored ? .brandNavy : .brandSky)
    }

    /// A summary without its Markdown marks, for a few lines of the card.
    private static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                var line = line
                for mark in ["- [ ] ", "- [x] ", "- ", "* ", "**"] { line = line.replacingOccurrences(of: mark, with: "") }
                return line
            }
            .joined(separator: " ")
    }

    // MARK: Actions

    private func buttons(for note: Note) -> some View {
        let readOnly = BowlSharing.shared.isReadOnly(note)
        let canBeDone = note.isTodo && !note.isDone && !readOnly
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: canBeDone ? 5 : 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            tile("File", systemImage: "tray.and.arrow.down.fill", tint: .brandProject, id: "TriageFile") { file(note) }
                .disabled(readOnly)
            // A light sky wash with the outlined clock: navy here weighed more than the other tiles.
            tile("Later", systemImage: "clock", tint: .brandSky, id: "TriageLater") { laterNote = note }
                .disabled(readOnly)
            tile("Skip", systemImage: "arrow.right", tint: .secondary, id: "TriageSkip") { skip() }
            tile("Delete", systemImage: "trash.fill", tint: .red, id: "TriageDelete") {
                withAnimation(.snappy) { Undoable.trash([note], in: context) }
            }
            .disabled(readOnly)
            if canBeDone {
                tile("Done", systemImage: "checkmark.square.fill", tint: .brandTask, id: "TriageDone") { done(note) }
            }
        }
        .padding(.horizontal, 14)
    }

    private func tile(_ title: LocalizedStringKey, systemImage: String, tint: Color, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(tint == .secondary ? Color.primary : tint.readable)
            .background((tint == .secondary ? Color.gray : tint).opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// Into the suggestion; without one the bowl list opens.
    private func file(_ note: Note) {
        withAnimation(.snappy) {
            if !InboxTriage.file(note, bowls: projects, in: context) { bowlNote = note }
        }
    }

    private func skip() {
        withAnimation(.snappy) { triage?.advance(in: notes) }
    }

    /// A to-do done stays in the Inbox, ticked: triage moves on past it.
    private func done(_ note: Note) {
        withAnimation(.snappy) {
            triage?.advance(in: notes)
            Undoable.done([note], in: context)
        }
    }

    // MARK: Finished

    private var finished: some View {
        ContentUnavailableView {
            Label("Inbox Triaged", systemImage: "checkmark.circle")
        } description: {
            Text(Inbox.notes(notes).isEmpty
                 ? "Everything new has a place."
                 : "You went through everything new. What you skipped waits in the Inbox.")
        } actions: {
            Button { dismiss() } label: {
                Text("Done").font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandSky)
            .accessibilityIdentifier("TriageFinish")
        }
        .frame(maxHeight: .infinity)
    }
}

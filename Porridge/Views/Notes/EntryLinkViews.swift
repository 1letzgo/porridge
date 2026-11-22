import SwiftUI

/// The entries offered after "[[" while typing, over the keyboard bar: a tap links one; Return links the first.
struct EntryLinkSuggestions: View {
    let controller: NoteEditorController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.linkResults.enumerated()), id: \.element.id) { index, candidate in
                Button { controller.chooseLink(candidate) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: candidate.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(candidate.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(index == controller.linkHighlight ? Color.accentColor.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Link \(candidate.title)")
                if index < controller.linkResults.count - 1 { Divider().padding(.leading, 44) }
            }
        }
        .font(.body)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .modifier(SuggestionBackground())
        .frame(maxWidth: 520)
        .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link to Entry")
    }
}

private struct SuggestionBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// "Linked From" under an entry: the entries whose text links here. Then "Mentions": entries that name this one by
/// its title without a link, each with "Link" to make the name a link (not in view-only bowls).
struct EntryLinksSection: View {
    let note: Note

    @Environment(\.allNotes) private var allNotes
    @Environment(\.openNote) private var openNote
    @State private var linkedFrom: [Note] = []
    @State private var mentions: [Note] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !linkedFrom.isEmpty {
                group("Linked From") {
                    ForEach(linkedFrom) { other in
                        row(other) { EmptyView() }
                        if other.id != linkedFrom.last?.id { Divider() }
                    }
                }
            }
            if !mentions.isEmpty {
                group("Mentions") {
                    ForEach(mentions) { other in
                        row(other) {
                            if !BowlSharing.shared.isReadOnly(other) {
                                Button("Link") {
                                    withAnimation(.snappy) {
                                        if EntryLinks.linkMention(in: other, to: note) { refresh() }
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.brandLinkText)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Link \(other.displayTitle) to this entry")
                            }
                        }
                        if other.id != mentions.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, linkedFrom.isEmpty && mentions.isEmpty ? 0 : 12)
        .task(id: TaskKey(note: note.id, title: note.title, count: allNotes.count, latest: allNotes.first?.updatedAt)) {
            // A moment later: opening the page comes first.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func refresh() {
        linkedFrom = EntryLinks.backlinks(to: note.id, among: allNotes)
        mentions = EntryLinks.mentions(of: note, among: allNotes)
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brandNavy.readable)
            VStack(spacing: 0) { content() }
        }
    }

    private func row<Trailing: View>(_ other: Note, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Button { openNote(other.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: other.kindSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(other.displayTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(other.displayTitle)")
            trailing()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
    }

    private struct TaskKey: Equatable {
        let note: UUID
        let title: String
        let count: Int
        let latest: Date?
    }
}

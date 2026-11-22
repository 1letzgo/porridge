import SwiftUI

/// The weekly review (iOS sheet, Mac window): what came in this week, the meetings and documents, the open to-dos
/// with their due days and the bowls that grew. A summary, not a planner. Arrows step to earlier weeks; the model can
/// write a few sentences about the week on request.
struct WeeklyReviewView: View {
    let notes: [Note]
    let bowls: [NoteFolder]
    /// Opens an entry (and closes the review on iOS).
    var onOpen: (UUID) -> Void
    var onClose: (() -> Void)?

    @State private var offset = 0
    @State private var aiText: String?
    @State private var aiError: String?
    @State private var isWriting = false

    private static let sky = Color("BrandSkyText")
    private static let task = Color("BrandTaskText")

    private var review: WeeklyReview {
        WeeklyReview.make(notes: notes, bowls: bowls, week: WeeklyReview.week(containing: Date(), offset: offset))
    }

    var body: some View {
        let review = review
        VStack(spacing: 0) {
            header(review)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if review.isEmpty {
                        Text("Nothing came in this week.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        counts(review)
                        aiSection(review)
                        if !review.meetings.isEmpty { meetings(review) }
                        if !review.documents.isEmpty { documents(review) }
                        if !review.openTodos.isEmpty { todos(review) }
                        if !review.bowls.isEmpty { bowlsSection(review) }
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: offset) {
            aiText = nil
            aiError = nil
        }
    }

    private func header(_ review: WeeklyReview) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offset == 0 ? "This Week" : offset == -1 ? "Last Week" : "Week")
                    .font(.title2.weight(.bold))
                Text(review.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                .accessibilityLabel("Earlier Week")
                .help("Earlier Week")
            Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                .disabled(offset >= 0)
                .accessibilityLabel("Later Week")
                .help("Later Week")
            if let onClose {
                Button("Done", action: onClose)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func counts(_ review: WeeklyReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.total == 1 ? "1 new entry" : "\(review.total) new entries")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(review.counts, id: \.kind) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.kind.systemImage)
                            .foregroundStyle(Self.sky)
                            .frame(width: 20)
                        Text("\(item.count)")
                            .font(.body.weight(.semibold).monospacedDigit())
                        Text(item.kind.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
            if review.doneTodos > 0 {
                Label(review.doneTodos == 1 ? "1 to-do done" : "\(review.doneTodos) to-dos done", systemImage: "checkmark.square")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func aiSection(_ review: WeeklyReview) -> some View {
        if let aiText {
            VStack(alignment: .leading, spacing: 6) {
                Label("The Week in Short", systemImage: "sparkles").font(.headline)
                Text(aiText)
                    .textSelection(.enabled)
                Text("Written by \(SummaryModel.current.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    write(review)
                } label: {
                    if isWriting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Writing…")
                        }
                    } else {
                        Label("Summarize the Week with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isWriting)
                if let aiError {
                    Text(aiError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func row(_ id: UUID, systemImage: String, title: String, detail: String?, tint: Color = Self.sky, trailing: String? = nil, trailingTint: Color = .secondary) -> some View {
        Button { onOpen(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).foregroundStyle(.primary)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(trailingTint)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meetings(_ review: WeeklyReview) -> some View {
        section("Meetings", count: review.meetings.count) {
            ForEach(review.meetings) { meeting in
                let length = meeting.duration > 0 ? Duration.seconds(meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : nil
                row(
                    meeting.id, systemImage: "waveform", title: meeting.title,
                    detail: [meeting.date.formatted(.dateTime.weekday(.wide).hour().minute()), length].compactMap { $0 }.joined(separator: " · "),
                    trailing: meeting.pendingTodos > 0 ? (meeting.pendingTodos == 1 ? String(localized: "1 possible to-do") : String(localized: "\(meeting.pendingTodos) possible to-dos")) : nil,
                    trailingTint: Self.task
                )
            }
        }
    }

    private func documents(_ review: WeeklyReview) -> some View {
        section("Documents", count: review.documents.count) {
            ForEach(review.documents) { document in
                row(document.id, systemImage: "doc.richtext", title: document.title,
                    detail: [document.kind, document.sender].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private func todos(_ review: WeeklyReview) -> some View {
        section("Open To-dos", count: review.openTodos.count) {
            ForEach(review.openTodos) { todo in
                row(todo.id, systemImage: "square", title: todo.title, detail: todo.bowl, tint: Self.task,
                    trailing: todo.dueDay.map { Todos.dueLabel($0) }, trailingTint: todo.isOverdue ? .red : .secondary)
            }
        }
    }

    private func bowlsSection(_ review: WeeklyReview) -> some View {
        section("Bowls That Grew", count: review.bowls.count) {
            ForEach(review.bowls) { bowl in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Color("BrandProject")).frame(width: 20)
                    Text(bowl.name).lineLimit(1)
                    Spacer()
                    Text("+\(bowl.added)").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func write(_ review: WeeklyReview) {
        isWriting = true
        aiError = nil
        Task {
            do {
                let text = try await review.summarize(notes: notes)
                aiText = text.isEmpty ? nil : text
                if text.isEmpty { aiError = String(localized: "The model gave no answer.") }
            } catch {
                aiError = error.localizedDescription
            }
            isWriting = false
        }
    }
}

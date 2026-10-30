import SwiftUI

/// Chat with all notes and meetings: the questions are answered by the model chosen in Settings.
struct ChatView: View {
    let notes: [Note]
    let store: ChatStore
    /// Opens a note (a source of an answer) in the timeline.
    var onOpen: (UUID) -> Void

    @State private var input = ""
    @FocusState private var focused: Bool

    private let examples = [
        "What did we decide in the last meetings?",
        "Which tasks are still open?",
        "Summarize my notes of this week",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.messages.isEmpty {
                        intro
                    }
                    ForEach(store.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if store.isThinking {
                        thinking.id("thinking")
                    }
                    Color.clear.frame(height: 4).id("end")
                }
                .padding(.horizontal)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { scrollToEnd(proxy) }
            .onChange(of: store.isThinking) { scrollToEnd(proxy) }
        }
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
    }

    // MARK: Pieces

    private var intro: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                title: "Ask Your Notes",
                message: "Ask about anything in your notes and meetings. The answer comes from your own data.",
                systemImage: "bubble.left.and.text.bubble.right"
            )
            .frame(height: 260)
            VStack(spacing: 10) {
                ForEach(examples, id: \.self) { example in
                    Button { send(example) } label: {
                        Text(example)
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.brandSky.opacity(0.12), in: RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var thinking: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(store.status.isEmpty ? "Thinking …" : store.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(12)
                .background(Color.brandSky.opacity(0.16), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if message.isError {
                    Label(message.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    MarkdownText(markdown: message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.sources) { source in
                                Button { onOpen(source.noteID) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text").font(.caption.weight(.bold))
                                        Text(source.title).lineLimit(1)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .chunkyPill(fill: .brandSky)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 24)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your notes …", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.appBackground, in: RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous)
                        .strokeBorder(Look.hairline, lineWidth: Look.outline)
                )
            Button { send(input) } label: {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.brandSky, in: Circle())
                    .shadow(color: Color.brandSky.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isThinking)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.appBackground)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !store.isThinking else { return }
        input = ""
        Task { await store.ask(question, notes: notes) }
    }
}

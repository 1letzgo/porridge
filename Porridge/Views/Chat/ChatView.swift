import SwiftData
import SwiftUI

/// Where the chat page is: which chat shows, or the list of all of them. Kept by the list while the app runs, so
/// the bar of the page (its buttons) and the page itself see the same.
@MainActor
@Observable
final class ChatNavigation {
    /// The chat that shows; nil is a new one that is not kept until its first question.
    var openID: UUID?
    var showsList = false
    /// What a new chat is about (`Projects.key`); nil is all notes.
    var newScope: String?
    /// The bowl the chat was opened from: a new chat is about it.
    var project: String?

    /// Opening the chat from a bowl or the home list: the last chat about it is taken up again, otherwise a new one starts.
    func open(from project: String?, threads: [ChatThread]) {
        self.project = project
        newScope = project
        showsList = false
        openID = threads.first { $0.projectID == project }?.id
    }

    func startNew() {
        openID = nil
        newScope = project
        showsList = false
    }
}

/// The chat as a page of its own, reached from its button bottom left: one chat, or the list of all of them.
/// Chats are kept.
struct ChatPage: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Bindable var navigation: ChatNavigation
    /// Opens a note (a source of an answer).
    var onOpen: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]

    private var open: ChatThread? { navigation.openID.flatMap { id in threads.first { $0.id == id } } }

    var body: some View {
        Group {
            if navigation.showsList {
                ChatList(threads: threads, projects: projects, openID: navigation.openID) { thread in
                    navigation.openID = thread.id
                    navigation.showsList = false
                } onDelete: { thread in
                    delete(thread)
                }
            } else {
                ChatView(thread: open, notes: notes, projects: projects, scope: $navigation.newScope, onOpen: onOpen) { thread in
                    navigation.openID = thread.id
                }
            }
        }
        // Left: the model the chat loaded gives its memory back.
        .onDisappear { ChatService.shared.release() }
    }

    private func delete(_ thread: ChatThread) {
        let id = thread.id
        let entries = (try? context.fetch(FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.threadID == id }))) ?? []
        entries.forEach(context.delete)
        context.delete(thread)
        try? context.save()
        if navigation.openID == id { navigation.openID = nil }
    }
}

/// The buttons of the chat page's bar: the list of all chats and a new chat.
struct ChatBarActions: View {
    @Bindable var navigation: ChatNavigation
    @Query private var threads: [ChatThread]

    var body: some View {
        if !threads.isEmpty {
            Button { withAnimation(.snappy) { navigation.showsList.toggle() } } label: {
                Label(navigation.showsList ? "Back to Chat" : "All Chats", systemImage: navigation.showsList ? "bubble.left.and.text.bubble.right" : "list.bullet")
            }
            .accessibilityLabel(navigation.showsList ? "Back to Chat" : "All Chats")
            .help(navigation.showsList ? "Back to Chat" : "All Chats")
        }
        if navigation.openID != nil || navigation.showsList {
            Button { navigation.startNew() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .accessibilityLabel("New Chat")
            .help("New Chat")
        }
    }
}

/// All chats, the latest on top: a tap opens one, a swipe or a long press deletes it.
private struct ChatList: View {
    let threads: [ChatThread]
    let projects: [NoteFolder]
    let openID: UUID?
    var onOpen: (ChatThread) -> Void
    var onDelete: (ChatThread) -> Void

    var body: some View {
        List {
            ForEach(threads) { thread in
                Button { onOpen(thread) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ThingsRowIcon(systemImage: "bubble.left.and.bubble.right.fill", tint: .brandNavy)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title.isEmpty ? "New Chat" : thread.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(ChatView.scopeName(thread.projectID, projects: projects) + " · " + thread.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if thread.id == openID {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.brandNavy)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cardListRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { onDelete(thread) } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button(role: .destructive) { onDelete(thread) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .cardList()
    }
}

/// One chat with the notes: the questions are answered by the model chosen in Settings, from the passages of the
/// notes that fit. A chat is about all notes or about one bowl.
struct ChatView: View {
    /// The chat; nil is a new one, made with the first question.
    let thread: ChatThread?
    let notes: [Note]
    let projects: [NoteFolder]
    /// What a new chat is about.
    @Binding var scope: String?
    /// The model the chat answers with ("Chat Model" in Settings); nil is the default model.
    @State private var chatModel = SummaryModel.chatChoice
    var onOpen: (UUID) -> Void
    /// A new chat was made.
    var onCreate: (ChatThread) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatEntry.createdAt) private var allEntries: [ChatEntry]
    @State private var input = ""
    @FocusState private var focused: Bool

    private var service: ChatService { ChatService.shared }
    private var entries: [ChatEntry] {
        guard let id = thread?.id else { return [] }
        return allEntries.filter { $0.threadID == id }
    }
    private var isThinking: Bool { thread != nil && service.thinking == thread?.id }

    private let examples = [
        "What did we decide in the last meetings?",
        "Which tasks are still open?",
        "Summarize what came in this week",
    ]

    static func scopeName(_ project: String?, projects: [NoteFolder]) -> String {
        guard let project else { return String(localized: "All Bowls") }
        return projects.first { Projects.key($0) == project }?.name ?? String(localized: "Deleted Bowl")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    scopeRow
                    if entries.isEmpty { intro }
                    ForEach(entries) { entry in
                        bubble(entry).id(entry.id)
                    }
                    if isThinking { thinking.id("thinking") }
                    Color.clear.frame(height: 4).id("end")
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            // The newest message stays in view, also while the keyboard comes and goes; an empty chat starts at the top.
            .defaultScrollAnchor(entries.isEmpty ? .top : .bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.count) { scrollToEnd(proxy) }
            .onChange(of: isThinking) { scrollToEnd(proxy) }
            .onChange(of: focused) { _, isFocused in
                guard isFocused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    scrollToEnd(proxy)
                }
            }
        }
        // What was just changed from the chat, with Undo, above the field.
        .overlay(alignment: .bottom) {
            if let toast = service.toast {
                ChatUndoToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: service.toast?.id)
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
    }

    // MARK: Pieces

    /// What the chat is about. A new chat can still choose; a held one keeps what it was started with.
    private var scopeRow: some View {
        HStack(spacing: 8) {
            if let thread {
                scopePill(Self.scopeName(thread.projectID, projects: projects), chooses: false)
            } else {
                Menu {
                    Picker("About", selection: $scope) {
                        Label("All Bowls", systemImage: "tray.full").tag(String?.none)
                        ForEach(projects.filter { !$0.isArchived }) { project in
                            Label(project.name, systemImage: "folder").tag(Optional(Projects.key(project)))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    scopePill(Self.scopeName(scope, projects: projects), chooses: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Chat About")
            }
            Spacer(minLength: 0)
            modelMenu
        }
    }

    /// Which model answers, and a quick way to choose another: the same choice as "Chat Model" in Settings.
    @ViewBuilder private var modelMenu: some View {
        let models = SummaryModel.available
        if !models.isEmpty {
            Menu {
                Picker("Chat Model", selection: Binding(get: { chatModel }, set: {
                    chatModel = $0
                    SummaryModel.chatChoice = $0
                })) {
                    Text("Same as Default (\(SummaryModel.current.name))").tag(SummaryModel?.none)
                    ForEach(models) { model in
                        Text(model.menuTitle).tag(Optional(model))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: SummaryModel.chat.isLocal ? "cpu" : "cloud").font(.caption.weight(.bold))
                    Text(SummaryModel.chat.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brandSky.readable)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.brandSky.opacity(0.14), in: Capsule())
                .id(chatModel?.id ?? "default")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Chat Model")
            .accessibilityValue(SummaryModel.chat.name)
        }
    }

    private func scopePill(_ name: String, chooses: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.caption.weight(.bold))
            Text(name).lineLimit(1)
            if chooses { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.brandProject.readable)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.brandProject.opacity(0.14), in: Capsule())
    }

    private var intro: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                title: "Ask Your Bowls",
                message: "Ask about anything in your notes, meetings, links, images and files. The answer comes from your own data.",
                systemImage: "bubble.left.and.text.bubble.right"
            )
            .frame(height: 240)
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
            Text(service.status.isEmpty ? "Thinking…" : service.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bubble(_ entry: ChatEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(12)
                .background(Color.brandSky.opacity(0.16), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if entry.isError {
                    Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.brandDangerText)
                } else {
                    MarkdownText(markdown: entry.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The changes the answer proposes, to confirm.
                    ChatActionCards(entryID: entry.id)
                }
                let sources = entry.sources
                if !sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sources) { source in
                                Button { onOpen(source.noteID) } label: {
                                    HStack(spacing: 6) {
                                        // The kind of the note it comes from (`checklist` for a to-do), or a page when it is gone.
                                        Image(systemName: notes.first { $0.id == source.noteID }?.kindSymbol ?? "doc.text").font(.caption.weight(.bold))
                                        Text(source.title).lineLimit(1)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.brandNavy)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .chunkyPill(fill: .brandSky)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the note")
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
            TextField("Ask your bowls…", text: $input, axis: .vertical)
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
                .accessibilityIdentifier("ChatField")
            Button { send(input) } label: {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.brandNavy)
                    .frame(width: 48, height: 48)
                    .background(Color.brandSky, in: Circle())
                    .shadow(color: Color.brandSky.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.thinking != nil)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("ChatSend")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.appBackground)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, service.thinking == nil else { return }
        input = ""
        // A new chat is kept from its first question on.
        let chat: ChatThread
        if let thread {
            chat = thread
        } else {
            chat = ChatThread(projectID: scope)
            context.insert(chat)
            try? context.save()
            onCreate(chat)
        }
        Task { await service.ask(question, in: chat, notes: notes, projects: projects, context: context) }
    }
}

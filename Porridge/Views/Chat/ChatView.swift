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
    /// The open chat was picked in All Chats: going back returns there.
    var returnsToList = false
    /// What a new chat is about (`Projects.key`); nil is all notes.
    var newScope: String?
    /// The bowl the chat was opened from: a new chat is about it.
    var project: String?

    /// Opening the chat from a bowl or the home list: the last chat about it is taken up again, otherwise a new one starts.
    func open(from project: String?, threads: [ChatThread]) {
        self.project = project
        newScope = project
        showsList = false
        returnsToList = false
        openID = threads.first { $0.projectID == project }?.id
    }

    func startNew() {
        openID = nil
        newScope = project
        showsList = false
        returnsToList = false
    }

    /// All Chats, picked: that chat opens; going back returns to the list.
    func openFromList(_ id: UUID) {
        openID = id
        showsList = false
        returnsToList = true
    }

    /// The back pill on the Chat side: from a chat picked in All Chats back to the list, from any other chat and
    /// from All Chats to the chat's start (a new chat with the recent ones).
    func back() {
        if openID != nil, !showsList, returnsToList {
            returnsToList = false
            showsList = true
        } else {
            startNew()
        }
    }
}

/// The chat, the Search tab's Chat side: one chat, or the list of all of them. Chats are kept; a new chat
/// offers the recent ones to take up again.
struct ChatPage: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Bindable var navigation: ChatNavigation
    /// Opens a note (a source of an answer).
    var onOpen: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    /// A chat about to be deleted (it asks first).
    @State private var deleting: ChatThread?

    private var open: ChatThread? { navigation.openID.flatMap { id in threads.first { $0.id == id } } }

    var body: some View {
        Group {
            if navigation.showsList {
                ChatList(threads: threads, projects: projects, openID: navigation.openID) { thread in
                    navigation.openFromList(thread.id)
                } onDelete: { thread in
                    deleting = thread
                }
            } else {
                ChatView(
                    thread: open, notes: notes, projects: projects, scope: $navigation.newScope,
                    recent: open == nil ? SearchAsk.recentChats(threads) : [],
                    onOpen: onOpen,
                    onOpenChat: { thread in navigation.openID = thread.id },
                    onAllChats: { withAnimation(.snappy) { navigation.showsList = true } }
                ) { thread in
                    navigation.openID = thread.id
                }
            }
        }
        // Left: the model the chat loaded gives its memory back.
        .onDisappear { ChatService.shared.release() }
        .alert(
            "Delete “\(deleting.map { $0.title.isEmpty ? String(localized: "New Chat") : $0.title } ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { thread in
            Button("Delete Chat", role: .destructive) { delete(thread) }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Its questions and answers are deleted from this iPhone. You can undo this right after.")
        }
    }

    /// Deleted with the one undo toast (`ChatDeletion`): the chat comes back with its answers and their changes.
    private func delete(_ thread: ChatThread) {
        let id = thread.id
        ChatDeletion.delete(thread, in: context)
        if navigation.openID == id { navigation.openID = nil }
        deleting = nil
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
                            Text(SearchAsk.chatName(thread.projectID, bowls: projects) + " · " + thread.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
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
                    Button(role: .destructive) { onDelete(thread) } label: { Label("Delete Chat…", systemImage: "trash") }
                }
                .accessibilityAction(named: "Delete Chat") { onDelete(thread) }
            }
        }
        .cardList()
    }
}

/// One chat with the notes: the questions are answered by the model chosen in Settings, from the passages of the
/// notes that fit. A chat is about all notes, the Inbox or one bowl; that can be changed at any time and holds from
/// the next question on (earlier answers keep their sources).
struct ChatView: View {
    /// The chat; nil is a new one, made with the first question.
    let thread: ChatThread?
    let notes: [Note]
    let projects: [NoteFolder]
    /// What a new chat is about.
    @Binding var scope: String?
    /// The chats to take up again, shown while no chat is open.
    var recent: [ChatThread] = []
    /// The model the chat answers with ("Chat Model" in Settings); nil is the default model.
    @State private var chatModel = SummaryModel.chatChoice
    var onOpen: (UUID) -> Void
    var onOpenChat: (ChatThread) -> Void = { _ in }
    var onAllChats: () -> Void = {}
    /// A new chat was made.
    var onCreate: (ChatThread) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
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
        SearchAsk.chatName(project, bowls: projects)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    scopeRow
                    if let hint = SummaryModel.chat.sendsHint("question and excerpts of your notes") {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("hint-\(chatModel?.id ?? "default")")
                    }
                    if entries.isEmpty {
                        if !recent.isEmpty { recentChats }
                        intro
                    }
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
            .defaultScrollAnchor(entries.isEmpty ? .top : .bottom, for: .initialOffset)
            // A short chat stays at the top under the pills instead of sinking to the field.
            .defaultScrollAnchor(.top, for: .alignment)
            // The keyboard goes with a drag down through the conversation, or a tap in it (also where it is empty:
            // a short chat does not scroll).
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .accessibilityIdentifier("ChatConversation")
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
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
    }

    // MARK: Pieces

    /// What the chat is about: changeable at any time; in a chat that runs it holds from the next question on.
    private var scopeRow: some View {
        let current = thread?.projectID ?? scope
        // The largest text sizes: the two pills one under the other, so neither is cut to "A… ⌄".
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Menu {
                Picker("About", selection: Binding(get: { current }, set: { choose($0) })) {
                    Label("All Bowls", systemImage: "tray.full").tag(String?.none)
                    Label("Inbox", systemImage: "tray.fill").tag(Optional(SearchAsk.inboxKey))
                    ForEach(projects.filter { !$0.isArchived || Projects.key($0) == current }) { project in
                        Label(project.name, systemImage: "folder").tag(Optional(Projects.key(project)))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                scopePill(Self.scopeName(current, projects: projects), chooses: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Chat About")
            .accessibilityValue(Self.scopeName(current, projects: projects))
            if !large { Spacer(minLength: 0) }
            modelMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Another scope: a new chat starts with it, a running one asks the next question about it.
    private func choose(_ key: String?) {
        scope = key
        guard let thread, thread.projectID != key else { return }
        thread.projectID = key
        try? context.save()
    }

    /// The latest chats, to take up again, and the way to all of them.
    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 0) {
            let large = typeSize.isAccessibilitySize
            (large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
                Text("Recent Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                if !large { Spacer() }
                Button("All Chats", action: onAllChats)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("RecentAllChats")
            }
            .padding(.bottom, 6)
            ForEach(recent) { chat in
                Button { onOpenChat(chat) } label: {
                    // With the largest text sizes the row is tall: the icon stays by the first line.
                    HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                        ThingsRowIcon(systemImage: "bubble.left.and.bubble.right.fill", tint: .brandNavy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title.isEmpty ? String(localized: "New Chat") : chat.title)
                                .foregroundStyle(.primary)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                            Text(Self.scopeName(chat.projectID, projects: projects) + " · " + chat.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("RecentChat")
                if chat.id != recent.last?.id { Divider().padding(.leading, ThingsRowIcon.inset) }
            }
        }
        .padding(12)
        .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
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
                    Text(SummaryModel.chat.name).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
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
            Text(name).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
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
                    // In a row that scrolls; with the largest text sizes one under the other, each whole.
                    let large = typeSize.isAccessibilitySize
                    ScrollView(large ? [] : .horizontal, showsIndicators: false) {
                        (large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                            ForEach(sources) { source in
                                // Gone since (deleted, or a copy of a bowl that was left): shown, not opened.
                                let note = notes.first { $0.id == source.noteID }
                                Button { onOpen(source.noteID) } label: {
                                    HStack(spacing: 6) {
                                        // The kind of the note it comes from (`checklist` for a to-do), or a page when it is gone.
                                        Image(systemName: note?.kindSymbol ?? "doc.text").font(.caption.weight(.bold))
                                        Text(source.title).lineLimit(large ? 3 : 1)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.brandNavy)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .chunkyPill(fill: .brandSky)
                                }
                                .buttonStyle(.plain)
                                .disabled(note == nil)
                                .opacity(note == nil ? 0.5 : 1)
                                .accessibilityHint(note == nil ? "The note is gone" : "Opens the note")
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
        // The answer comes in where the keyboard was: it does not stay over it.
        focused = false
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

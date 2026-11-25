import AVFoundation
import PDFKit
import SwiftData
import SwiftUI
import UIKit

private enum NoteTab: Hashable {
    case note
    case transcript
    case article
    case summary
}

struct NoteDetailView: View {
    /// A new note is only in memory until it has content; then it is saved (see `saveIfFilled`).
    @Bindable var note: Note
    /// Called after the note was moved to "Recently Deleted" or recovered, so the list can close it.
    var onClose: () -> Void = {}
    /// A note that was just created records right away.
    var startsRecording = false
    /// On a phone: the note has the app's own bar, with a back pill that calls this. Nil: the system's bar.
    var onBack: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(ModelManager.self) private var models
    @Environment(\.allNotes) private var allNotes
    @Environment(\.openNote) private var openNote
    @Environment(\.askAboutBowl) private var askAboutBowl
    @Environment(\.openURL) private var openURL
    @State private var dictation = InlineDictation()
    @State private var didStartRecording = false
    @State private var showExport = false
    @State private var showContinueRecording = false
    @State private var confirmContinueRecording = false
    /// Character offset where the current dictation starts; text before it is never changed.
    @State private var dictationStart = 0
    /// Live text of the running dictation; only shown, written to the note when the final text is ready.
    @State private var liveText = ""
    @State private var editor = NoteEditorController()
    @State private var tab = NoteTab.note
    @State private var showSummaryOptions = false
    @State private var showEnhanceOptions = false
    @State private var player = AudioPlayback()
    @State private var renamingSpeaker: Speaker?
    @State private var renameText = ""
    @State private var confirmDeleteAudio = false
    @State private var isFetchingAudio = false
    @State private var fetchAudioError: String?
    /// Redraws when a recording arrived from iCloud: the file on disk is not observed.
    @State private var fetchedAudio = 0
    @State private var confirmDeleteSummary = false
    @State private var showMerge = false
    /// The page editor of the document's PDF.
    @State private var showPages = false
    /// "Save as Template": the editor with a template made from this entry.
    @State private var templateDraft: NoteTemplateDraft?
    @State private var showSummaryEditor = false
    /// Details is open (at a section).
    @State private var details: DetailsRequest?
    @State private var showVoices = false
    /// Pages of the document's PDF, once counted (for the meta line).
    @State private var pageCount: Int?
    /// The page editor opens with the scanner (More › Scan More Pages).
    @State private var scansPages = false
    /// Rewrite Selection… was chosen with nothing selected.
    @State private var rewriteNeedsSelection = false
    /// Delete Now… in Recently Deleted asks first.
    @State private var confirmDeleteNow = false
    /// "Split into Bowl…" is open; after it, what it made, while it can be taken back.
    @State private var showSplit = false
    /// The screen was shown before: coming back (from Quick Look, a sheet) keeps the open tab.
    @State private var didAppear = false
    /// What someone else did to the note in a shared bowl, as it was when the note was opened ("Changed by Ben").
    @State private var openedActivity: String?
    @FocusState private var focused: Bool
    @Query(sort: \NoteFolder.name) private var bowls: [NoteFolder]
    /// Height of one line of the title (title2, bold), as the text field lays it out: the box stands centered on it.
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28

    /// The tabs of this note: a recording has a transcript and no text field of its own (unless it has text).
    private var opensOnSummary: Bool { note.isRecording || note.isLink || note.isStored }

    private var tabs: [(NoteTab, String)] {
        var list: [(NoteTab, String)] = []
        // Meetings and links open on their summary (first tab); they have no text field of their own unless they have text.
        if opensOnSummary { list.append((.summary, "Summary")) }
        // The tab stays while it is open, even when its text was just cleared.
        if !opensOnSummary || !note.text.isEmpty || tab == .note { list.append((.note, "Note")) }
        if note.isRecording { list.append((.transcript, "Transcript")) }
        if note.isLink { list.append((.article, "Article")) }
        // What was read out of the note's images and PDFs.
        else if note.attachmentsData != nil, !(note.pageText ?? "").isEmpty { list.append((.article, "Text")) }
        // A plain note is enhanced, not summarized; one summarized earlier keeps its summary.
        if !opensOnSummary, note.summary != nil || isSummarizing || tab == .summary { list.append((.summary, "Summary")) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if note.isDeleted { deletedBanner }

            if isReadOnly { readOnlyBanner }

            if note.attachmentsData != nil, !note.stripAttachments.isEmpty {
                AttachmentStrip(note: note, onRemove: isLocked ? nil : { removeAttachment($0) })
            }

            statusView

            if tabs.count > 1 {
                TabSwitcher(selection: $tab, options: tabs.map { (value: $0.0, title: $0.1) })
            }

            switch tab {
            case .summary:
                summaryTab
            case .transcript:
                transcriptTab
            case .article:
                articleTab
            case .note:
                if dictation.phase != .idle {
                    DictationStatus(dictation: dictation)
                    dictationPreview
                } else {
                    NoteBodyEditor(
                        text: $note.text, isEditable: !isLocked && !isEnhancing, controller: editor,
                        placeholder: note.isTodo ? "Notes and subtasks…" : "Start typing or dictate…", growsWithText: true
                    )
                    if note.isTodo, !isLocked, !isEnhancing {
                        addSubtaskButton
                    }
                    // Lines that read like tasks, offered as to-dos (never on links or saved files).
                    if TaskDetection.applies(to: note), !isLocked, !isEnhancing {
                        TaskDetectionBar(note: note, beforeChange: commitTyping)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .modifier(NotePageScroll(following: liveText, isEditing: editor.isEditing))
        .overlay(alignment: .bottom) {
            if editor.isEditing, !isLocked, tab == .note, dictation.phase == .idle {
                VStack(spacing: 8) {
                    // After "[[": the entries to link.
                    if editor.linkSearch != nil, !editor.linkResults.isEmpty {
                        EntryLinkSuggestions(controller: editor)
                    }
                    NoteKeyboardBar(controller: editor, dictate: canDictate ? { Task { await toggleDictation() } } : nil)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .animation(.snappy, value: editor.linkResults.map(\.id))
            }
        }
        .background(Color.appBackground)
        .inlineNavigationTitle()
        .keyboardDoneBar(isShown: focused) { focused = false }
        .safeAreaInset(edge: .bottom) {
            if fetchedAudio >= 0, tab != .note, !focused {
                if note.hasLocalAudio {
                    PlayerBar(player: player) { confirmDeleteAudio = true }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                } else if isFetchingAudio || fetchAudioError != nil || note.canFetchAudio {
                    fetchAudioBar
                }
            }
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let onBack {
                ChromeBar(title: barTitle, systemImage: barIcon, tint: barTint, onBack: onBack) {
                    aiMenu
                    shareAction
                    moreMenu
                }
                .padding(.bottom, Look.headerGap)
                .background(Color.appBackground)
            }
        }
        .toolbar(onBack == nil ? .automatic : .hidden, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            // Dictation starts from the mic in the editor bar; while it runs (the keyboard is away) this button stops it.
            if tab == .note, canDictate, dictation.phase != .idle {
                DictationButton(dictation: dictation) {
                    Task { await toggleDictation() }
                }
                .padding(.trailing, 20)
                .padding(.bottom, editor.isEditing || focused ? 66 : 16)
                .animation(.snappy, value: editor.isEditing || focused)
            }
        }
        .onAppear {
            editor.attachImage = { [note, context, processing] url in
                NoteImageAttaching.attach(url, to: note, context: context, processing: processing)
            }
            editor.hasAttachment = { [note] name in note.attachments.contains { $0.fileName == name } }
            editor.noteTitle = { [note] in note.title }
            // "[[" links another entry; a tap on a link opens it.
            // The entries as they are when "[[" is typed (not when the page opened: newer ones and new titles count).
            editor.linkCandidates = { [note, context] query in
                let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
                return EntryLinks.candidates(for: query, among: notes, excluding: note.id)
            }
            editor.openEntry = { [openNote] id in
                commitTyping()
                openNote(id)
            }
            // What someone else added or changed: said once more here, and seen from now on.
            if !didAppear { openedActivity = BowlSharing.shared.activityLine(for: note) }
            BowlSharing.shared.markSeen(note)
            // Loading the same file again keeps the player where it was.
            if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
            guard !didAppear else { return }
            didAppear = true
            // Load the speech model right away so the first piece is transcribed without delay.
            Task { try? await ModelManager.shared.ensureASR() }
            tab = opensOnSummary || isSummarizing ? .summary : .note
        }
        .task(id: note.audioFileName) {
            // A recording in iCloud is downloaded when its note is opened, then it plays.
            await fetchAudio()
        }
        .task {
            guard startsRecording, !didStartRecording, AppSettings.recordsNewNotes else { return }
            didStartRecording = true
            // Without the microphone there is only the keyboard; the question comes up once, not with every note.
            guard AVAudioApplication.shared.recordPermission != .denied else { return }
            // After the editor took the focus it gives a new note, so the keyboard goes away again.
            try? await Task.sleep(for: .milliseconds(300))
            if dictation.phase == .idle { await toggleDictation() }
        }
        .onDisappear {
            player.stop()
            if dictation.phase == .recording {
                Task { await finishDictation() }
            }
            // Typing of the last moment reaches the note now: once this screen is gone, `onChange(of: note.text)`
            // no longer runs, and a new note that was never stored would be dropped by the list.
            commitTyping()
            saveIfFilled()
            try? context.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .porridgeStopRecording)) { _ in
            if dictation.phase == .recording { Task { await finishDictation() } }
        }
        .onChange(of: note.text) { old, _ in
            note.updatedAt = Date()
            // A box ticked in the editor, a subtask added: the to-do follows.
            Todos.follow(note, from: old)
            saveIfFilled()
        }
        .onChange(of: note.title) {
            note.updatedAt = Date()
            saveIfFilled()
        }
        .sheet(item: $details) { request in
            EntryDetailsSheet(note: note, activity: openedActivity, section: request.section) { openNote($0) }
        }
        .sheet(isPresented: $showVoices) { KnownVoicesSheet() }
        .task(id: note.attachments.first { $0.kind == .pdf }?.fileName) { countPages() }
        .sheet(isPresented: $showExport) {
            MeetingExportSheet(note: note)
        }
        .fullScreenCoverOrSheet(isPresented: $showContinueRecording) {
            RecordingView(title: note.title, continues: note.id) { result, _, _, written in
                note.addRecordedPart(result.fileName, written: written)
                try? context.save()
                processing.enqueue(.note(note.id))
                tab = .transcript
            }
        }
        .alert("Continue Recording?", isPresented: $confirmContinueRecording) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { showContinueRecording = true }
        } message: {
            Text("The new part is added to the meeting. The summary is removed and can be written again.")
        }
        .onChange(of: note.audioFileName) {
            // The recording was replaced by the joined one.
            player.stop()
            if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
        }
        .sheet(isPresented: $showSummaryEditor) {
            // Cleaned up from the sheet itself, once its editor has handed over the last typing.
            SummaryEditorSheet(text: Binding(get: { note.summary ?? "" }, set: { note.summary = $0 }), onFinish: finishEditingSummary)
        }
        .sheet(isPresented: $showPages) { PDFPageEditor(note: note, startsScanning: scansPages) }
        .alert("Select Text to Rewrite", isPresented: $rewriteNeedsSelection) {
            Button("OK") {}
        } message: {
            Text("Select the words in the note that AI should rewrite, then choose Rewrite Selection… again.")
        }
        .alert("Delete Now?", isPresented: $confirmDeleteNow) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Now", role: .destructive) {
                NoteStore.deletePermanently(note, in: context)
                onClose()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(item: $templateDraft) { draft in NoteTemplateEditor(draft: draft) }
        .sheet(isPresented: $showSplit) {
            SplitNoteSheet(note: note) { change in
                BowlMaking.offerUndo(change, in: context)
            }
        }
        // The undo toast takes an enhance back: typing still on its way is handed over first, so the undo rightly
        // does nothing when the text was changed since.
        .onReceive(NotificationCenter.default.publisher(for: ProcessingService.willUndoEnhance)) { notification in
            if notification.object as? UUID == note.id { commitTyping() }
        }
        .sheet(isPresented: $showMerge) {
            MergeNotesSheet(base: note) {
                // The recording may have been replaced by the joined one.
                player.stop()
                if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
                tab = .transcript
            }
        }
        .sheet(isPresented: $showEnhanceOptions) {
            SummaryOptionsSheet(replacesSummary: false, showsTemplates: false, material: "note", enhances: true) { _, model in
                enhance(model: model)
            }
        }
        .alert("Enhance Failed", isPresented: .constant(processing.enhanceErrors[note.id] != nil)) {
            Button("OK") { processing.clearEnhanceError(note.id) }
        } message: {
            Text(processing.enhanceErrors[note.id] ?? "")
        }
        .sheet(isPresented: $showSummaryOptions) {
            SummaryOptionsSheet(
                replacesSummary: note.summary != nil,
                showsTemplates: !note.segments.isEmpty,
                material: !note.segments.isEmpty ? "transcript" : note.isLink ? "page" : "note"
            ) { template, model in
                summarize(template: template, model: model)
            }
        }
        .alert("Delete Summary?", isPresented: $confirmDeleteSummary) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Summary", role: .destructive, action: deleteSummary)
        } message: {
            Text("Your edits and check marks in it are lost. You can write a new one at any time.")
        }
        .alert("Delete Recording?", isPresented: $confirmDeleteAudio) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Recording", role: .destructive, action: deleteAudio)
        } message: {
            Text(AudioStore.deleteRecordingMessage)
        }
        .alert("Rename Speaker", isPresented: .constant(renamingSpeaker != nil)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Save") { commitRename() }
        }
        .alert("Summary Failed", isPresented: .constant(summaryError != nil)) {
            Button("OK") { processing.clearSummaryError(note.id) }
        } message: {
            Text(summaryError ?? "")
        }
        .alert("Can't Dictate", isPresented: .constant(dictation.errorMessage != nil && dictation.phase == .idle)) {
            Button("OK") { dictation.dismissError() }
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top-aligned, the box centered on the first line: an empty title field has no text baseline, so
            // aligning by baseline dropped the placeholder a line below the box until the first letter was typed.
            HStack(alignment: .top, spacing: 10) {
                if note.isTodo {
                    TodoCheckbox(isDone: note.isDone, size: 26) {
                        // What the box showed when it was tapped, before the typing that is handed over now moves it.
                        let done = !note.isDone
                        commitTyping()
                        withAnimation(.snappy) { Todos.setDone(done, note, in: context) }
                    }
                    .disabled(isLocked)
                    .frame(minHeight: titleLineHeight)
                }
                TextField(note.isTodo ? "To-do" : "Title", text: Binding(
                    get: { note.title },
                    set: { typed in
                        // The field wraps long titles, but Return ends the title: no line break is kept in it
                        // (it showed as an empty second line in every list).
                        if typed.contains(where: \.isNewline) {
                            note.title = typed.filter { !$0.isNewline }
                            focused = false
                        } else {
                            note.title = typed
                        }
                        note.titleIsCustom = true
                    }
                ), axis: .vertical)
                .font(.title2.weight(.bold))
                .foregroundStyle(note.isDone ? Color.secondary : Color.brandNavy)
                .strikethrough(note.isDone, color: .secondary)
                .accessibilityIdentifier("Title")
                .focused($focused)
                .disabled(isLocked)
            }

            if let source = todoSource {
                TodoSourcePill(source: source)
            }

            if let address = note.linkURL, let domain = note.domain {
                Link(destination: address) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(domain).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandLinkText)
                }
                .accessibilityLabel("Open \(domain)")
            }

            let state = entryContext
            let meta = EntryMeta.items(for: note, context: state)
            EntryMetaLine(
                facts: meta.facts, values: meta.values, suggestion: EntryMeta.suggestion(for: note, context: state),
                onOpen: { openDetails(at: $0) },
                onFile: { bowl in
                    withAnimation(.snappy) { Undoable.move([note], toBowl: Projects.key(bowl), named: bowl.name, in: context) }
                },
                onDropSuggestion: {
                    withAnimation(.snappy) { Inbox.dismissSuggestions(note, in: context) }
                }
            )
            .padding(.top, 2)
        }
    }

    /// What the head and Details read: the live state, with the activity as it was when the entry was opened
    /// (opening it marked it as seen).
    private var entryContext: EntryContext {
        var state = EntryContext.live(for: note, bowls: bowls, processing: processing)
        if !note.isDeleted { state.activityLine = state.activityLine ?? openedActivity }
        state.pageCount = pageCount
        return state
    }

    private func openDetails(at section: EntryDetails.Section.Kind?) {
        commitTyping()
        focused = false
        details = DetailsRequest(section: section)
    }

    /// The pages of the document's PDF, when its file is here.
    private func countPages() {
        guard let pdf = DocumentFiles.pdf(of: note), AttachmentStore.exists(pdf) else {
            pageCount = nil
            return
        }
        pageCount = PDFDocument(url: AttachmentStore.url(for: pdf))?.pageCount
    }

    /// In a bowl shared with me to see only: nothing of the entry can be changed here.
    private var isReadOnly: Bool { !note.isDeleted && BowlSharing.shared.isReadOnly(note) }

    /// Nothing can be changed: the note is in Recently Deleted, or in a bowl I may only see.
    private var isLocked: Bool { note.isDeleted || isReadOnly }

    private var readOnlyBanner: some View {
        Label("Shared with you to view only", systemImage: "eye")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brandNavy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatPanel(.gray)
    }

    @ViewBuilder
    private var statusView: some View {
        if let stage = processing.stages[note.id], !isSummarizing {
            HStack(spacing: 12) {
                ProgressView().tint(Color.brandNavy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage).font(.subheadline.weight(.semibold))
                    if case .downloading(let progress) = models.asr {
                        Text("Downloading Parakeet v3 (one time) – \(Int(progress * 100)) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .flatPanel()
        } else if note.status == .ready, note.isRecording, let message = note.errorMessage, note.speakerMode == .none {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "person.2.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if note.hasAudio {
                    Button("Detect Speakers Again") { processing.enqueue(.transcript(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                }
            }
            .flatPanel(.gray)
        } else if note.status == .failed {
            VStack(alignment: .leading, spacing: 12) {
                Label(note.errorMessage ?? "Transcription failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.brandDangerText)
                if note.isLink {
                    Button("Try Again") {
                        note.status = .recorded
                        processing.enqueue(.link(note.id, summarize: false))
                    }
                    .buttonStyle(ChunkyButtonStyle())
                } else if note.attachmentsData != nil, !note.isRecording {
                    Button("Try Again") { processing.enqueue(.attachment(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                } else if AudioStore.exists(note.pendingAudioFileName) {
                    Button("Try Again") { processing.enqueue(.note(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                } else if note.hasAudio {
                    Button("Try Again") { processing.enqueue(.transcript(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                }
            }
            .flatPanel(.red)
        }
    }

    /// Takes a file off the note and deletes it, here and in iCloud.
    private func removeAttachment(_ attachment: Attachment) {
        note.removeAttachment(id: attachment.id)
        AudioStore.delete(attachment.fileName)
        note.updatedAt = Date()
        if note.attachments.isEmpty {
            if !note.isLink { note.pageText = nil }
        } else {
            processing.enqueue(.attachment(note.id))
        }
        try? context.save()
    }

    // MARK: - Toolbar

    /// The kind as the head names it ("Meeting", "To-do", "PDF", "Image").
    private var barTitle: String { EntryMeta.kindWord(for: note) }
    private var barIcon: String { note.kindSymbol }
    private var barTint: Color { note.isTodo ? .brandTask : note.isLink ? .brandLink : note.isRecording || note.isStored ? .brandNavy : .brandSky }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        BrandToolbarItem(placement: .primaryAction) { aiMenu.buttonStyle(.plain) }
        BrandToolbarItem(placement: .primaryAction) { shareAction }
        BrandToolbarItem(placement: .primaryAction) { moreMenu.buttonStyle(.plain) }
    }

    // MARK: ✦ AI · Share · ⋯ More (`EntryMenus`)

    /// ✦ AI: what a model does to this entry, then Ask About This Bowl. Locked in Recently Deleted.
    private var aiMenu: some View {
        let groups = EntryMenus.ai(for: note, context: entryContext)
        return Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(Array(group.enumerated()), id: \.offset) { _, item in
                    Button { run(item) } label: { Label(item.title, systemImage: item.systemImage) }
                        .disabled(!isEnabled(item))
                }
            }
        } label: {
            BrandMenuLabel(title: "AI", systemImage: "sparkles")
        }
        .disabled(groups.isEmpty)
        .accessibilityLabel("AI")
        .accessibilityIdentifier("entry.ai")
        .help("AI")
    }

    /// Share hands over what the entry is: its text, a meeting's export sheet, the link, the picture or the file.
    @ViewBuilder
    private var shareAction: some View {
        switch EntryMenus.share(for: note) {
        case .exportSheet:
            Button { showExport = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .brandToolbarButton()
                .accessibilityLabel("Share")
                .accessibilityIdentifier("entry.share")
                .help("Share")
        case .url:
            if let address = note.linkURL { shareLink(address) } else { shareLink(shareText) }
        case .image, .file:
            if let file = EntryMenus.shareFile(for: note) { shareLink(file) } else { shareLink(shareText) }
        case .markdown, .todoText:
            shareLink(shareText)
        case nil:
            // Recently Deleted: nothing leaves from there.
            Button {} label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(true)
                .accessibilityLabel("Share")
                .accessibilityIdentifier("entry.share")
        }
    }

    private func shareLink(_ text: String) -> some View {
        shareStyle(ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") })
    }

    private func shareLink(_ url: URL) -> some View {
        shareStyle(ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") })
    }

    private func shareStyle(_ link: some View) -> some View {
        link
        .brandToolbarButton()
        .accessibilityLabel("Share")
        .accessibilityIdentifier("entry.share")
        .help("Share")
    }

    /// ⋯ More: organize, (meetings) Recording, Save as Template, Delete; in Recently Deleted Recover and Delete Now.
    private var moreMenu: some View {
        let groups = EntryMenus.more(for: note, context: entryContext)
        return Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(Array(group.enumerated()), id: \.offset) { _, item in
                    moreItem(item)
                }
            }
        } label: {
            BrandMenuLabel(title: "More", systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("entry.more")
        .help("More")
    }

    private func moreItem(_ item: EntryMenus.MoreItem) -> some View {
        Button(role: item.isDestructive ? .destructive : nil) { run(item) } label: {
            Label(item.title(for: note), systemImage: item.systemImage(for: note))
        }
        .disabled(!isEnabled(item))
    }

    /// Whether an AI item can be used right now (a model, no job running, a selection for Rewrite).
    private func isEnabled(_ item: EntryMenus.AIItem) -> Bool {
        switch item {
        case .enhance: canEnhance
        case .undoEnhance: true
        case .summarize: !isSummarizing && canSummarize
        case .suggestTodos: !isSummarizing && note.summary != nil
        case .rewriteSelection: tab == .note && !isEnhancing
        case .splitIntoBowl: !isEnhancing && !isSummarizing && NoteSplitter.canSplit(note)
        case .askAboutBowl: true
        }
    }

    /// Whether a More item can be used right now (no job running on the entry).
    private func isEnabled(_ item: EntryMenus.MoreItem) -> Bool {
        let idle = processing.stages[note.id] == nil
        switch item {
        case .transcribeAgain: return idle && note.hasAudio
        case .loadPageAgain, .editPages, .scanMorePages: return idle
        case .continueRecording: return canContinueRecording
        case .mergeWith: return idle && note.status == .ready && !note.segments.isEmpty
        case .copyTranscript: return !note.segments.isEmpty
        case .deleteRecording: return note.hasAudio
        case .openInBrowser, .copyLink: return note.linkURL != nil
        case .pin, .markDone, .convertToTodo, .convertToNote, .saveAsTemplate, .copy, .openInNewWindow,
             .delete, .recover, .deleteNow:
            return true
        }
    }

    /// Every item of ✦ AI has its handler here (the switch is the check that none is left out).
    private func run(_ item: EntryMenus.AIItem) {
        switch item {
        case .enhance:
            commitTyping()
            showEnhanceOptions = true
        case .undoEnhance:
            commitTyping()
            processing.undoEnhance(note)
        case .summarize:
            requestSummary()
        case .suggestTodos:
            // The tasks of the summary as to-dos again, dismissed ones included.
            withAnimation(.snappy) { TodoSuggestions.suggestAgain(note, in: context) }
            tab = .summary
        case .rewriteSelection:
            if editor.canRewrite { editor.beginRewrite() } else { rewriteNeedsSelection = true }
        case .splitIntoBowl:
            commitTyping()
            showSplit = true
        case .askAboutBowl:
            commitTyping()
            if let bowl = note.projectIDs.first { askAboutBowl(bowl) }
        }
    }

    /// Every item of ⋯ More has its handler here (the switch is the check that none is left out).
    private func run(_ item: EntryMenus.MoreItem) {
        switch item {
        case .pin:
            note.isPinned.toggle()
            note.updatedAt = Date()
            try? context.save()
        case .markDone:
            // What the box showed when it was tapped, before the typing that is handed over now moves it.
            let done = !note.isDone
            commitTyping()
            withAnimation(.snappy) { Todos.setDone(done, note, in: context) }
        case .convertToTodo, .convertToNote:
            commitTyping()
            withAnimation(.snappy) { Todos.setTodo(item == .convertToTodo, note, in: context) }
        case .editPages:
            scansPages = false
            showPages = true
        case .scanMorePages:
            scansPages = true
            showPages = true
        case .openInBrowser:
            if let address = note.linkURL { openURL(address) }
        case .copyLink:
            if let address = note.linkURL { Clipboard.copy(address.absoluteString) }
        case .loadPageAgain:
            note.status = .recorded
            processing.enqueue(.link(note.id, summarize: false))
        case .continueRecording:
            if note.summary == nil { showContinueRecording = true } else { confirmContinueRecording = true }
        case .transcribeAgain:
            processing.enqueue(.transcript(note.id))
        case .mergeWith:
            showMerge = true
        case .copyTranscript:
            Clipboard.copy(note.transcriptText())
        case .deleteRecording:
            confirmDeleteAudio = true
        case .saveAsTemplate:
            commitTyping()
            templateDraft = .new(NoteTemplates.draft(from: note))
        case .copy:
            commitTyping()
            Clipboard.copy(EntryMenus.copyText(for: note))
        case .openInNewWindow:
            // The Mac's; the iPhone shows one entry at a time.
            break
        case .delete:
            commitTyping()
            Undoable.trash([note], in: context)
            onClose()
        case .recover:
            restore()
        case .deleteNow:
            confirmDeleteNow = true
        }
    }

    /// A recording that is only on another device (not in iCloud) could not be joined with the new part.
    private var canContinueRecording: Bool {
        processing.stages[note.id] == nil && note.status == .ready && note.pendingAudioFileName == nil
            && (note.audioFileName == nil || note.hasAudio)
    }

    /// While the recording comes from iCloud: a spinner; after a failure the reason and a button to try again.
    private var fetchAudioBar: some View {
        VStack(spacing: 6) {
            if isFetchingAudio {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.brandNavy)
                    Text("Downloading Recording…").font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                Button {
                    Task { await fetchAudio() }
                } label: {
                    Label("Download Recording", systemImage: "arrow.down.circle")
                }
                .buttonStyle(ChunkyButtonStyle())
            }
            if let fetchAudioError {
                Text(fetchAudioError).font(.footnote).foregroundStyle(Color.brandDangerText)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Downloads the recording when it is in iCloud and not here yet, then loads it into the player.
    private func fetchAudio() async {
        // At launch the iCloud container may still be looked for.
        _ = await AudioStore.cloudContainer()
        guard let name = note.audioFileName, !isFetchingAudio else { return }
        guard !note.hasLocalAudio, AudioStore.isInCloud(name) else {
            // Found only now that the container is known: already downloaded.
            if note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
            fetchedAudio += 1
            return
        }
        isFetchingAudio = true
        fetchAudioError = nil
        defer {
            isFetchingAudio = false
            fetchedAudio += 1
        }
        do {
            try await AudioStore.download(name)
            guard note.audioFileName == name else { return }
            player.load(AudioStore.url(for: name))
        } catch is CancellationError {
            // The note was closed; iCloud goes on with the download by itself.
        } catch {
            fetchAudioError = error.localizedDescription
        }
    }

    private var isSummarizing: Bool { processing.summarizing.contains(note.id) }
    private var isEnhancing: Bool { processing.enhancing.contains(note.id) }

    private var canEnhance: Bool {
        processing.stages[note.id] == nil && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var summaryError: String? { processing.summaryErrors[note.id] }

    private var canSummarize: Bool {
        processing.stages[note.id] == nil
            && !(note.text.isEmpty && note.title.isEmpty && note.segments.isEmpty && (note.pageText ?? "").isEmpty)
    }

    // MARK: - Article

    private var articleTab: some View {
        NoteTabScroll {
            if let text = note.pageText, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if (processing.stages[note.id] != nil && !isSummarizing) || note.pageText == nil, note.status != .failed {
                Text("The text of the page appears here once it is loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if note.status != .failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("There is no readable text on this page.")
                        .foregroundStyle(.secondary)
                    if let address = note.linkURL {
                        Link("Open in Browser", destination: address)
                            .buttonStyle(ChunkyButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptTab: some View {
        let segments = note.segments
        let speakers = note.speakers
        NoteTabScroll {
            if segments.isEmpty {
                Text(note.status == .ready ? "No speech was detected." : "The transcript appears here once processing is done.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(segments) { segment in
                        let speaker = speakers.first { $0.id == segment.speakerId }
                        SegmentRow(
                            segment: segment,
                            speaker: speaker,
                            isActive: player.isPlaying && player.currentTime >= segment.start && player.currentTime < segment.end,
                            speakerMenu: isLocked || speaker == nil ? nil : {
                                // A tap on the name: who the speaker is, or only this line to another one.
                                AnyView(SpeakerMenuItems(
                                    speaker: speaker!, note: note, segment: segment,
                                    askName: { askName(for: $0) }, showVoices: { showVoices = true }
                                ))
                            },
                            // The passage plays from a tap on its text (the name has its menu).
                            onPlay: note.hasLocalAudio ? {
                                player.seek(to: segment.start)
                                player.play()
                            } : nil
                        )
                        .contextMenu {
                            Button {
                                Clipboard.copy(segment.text)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            if speakers.count > 1, !isLocked {
                                Section("Assign Speaker") {
                                    ForEach(speakers) { speaker in
                                        Button(speaker.name) { reassign(segment, to: speaker) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func askName(for speaker: Speaker) {
        renameText = speaker.name
        renamingSpeaker = speaker
    }

    /// Also teaches the voice under this name and writes the summary again with it (`SpeakerNaming.rename`).
    private func rename(_ speaker: Speaker, to name: String) {
        SpeakerNaming.rename(speaker.id, to: name, in: note, context: context, processing: processing)
    }

    private func reassign(_ segment: TranscriptSegment, to speaker: Speaker) {
        note.segments = note.segments.map { item in
            var item = item
            if item.id == segment.id { item.speakerId = speaker.id }
            return item
        }
        try? context.save()
    }

    private func commitRename() {
        guard let speaker = renamingSpeaker else { return }
        // Also teaches the voice under this name; earlier unnamed speakers get checked against it.
        rename(speaker, to: renameText)
        renamingSpeaker = nil
    }

    /// Removes only the audio file; transcript, speakers and summary stay.
    private func deleteAudio() {
        player.stop()
        AudioStore.delete(note.audioFileName)
        note.audioFileName = nil
        try? context.save()
    }

    // MARK: - Summary

    private var summaryTab: some View {
        NoteTabScroll {
            if isSummarizing {
                SummarizingCard(message: summarizeMessage, status: processing.stages[note.id], model: processing.summaryModels[note.id]?.label ?? SummaryService.modelLabel)
            } else if let summary = note.summary {
                let made = Todos.madeFrom(note, among: allNotes)
                let suggestions = note.pendingTodoSuggestions(made: made)
                // The tasks the card above or the to-dos below show are left out of the summary: each once.
                let shown = note.summaryShown(offered: isReadOnly ? [] : suggestions, made: made) ?? summary
                VStack(spacing: 16) {
                    // The tasks of the summary offered as to-dos, first thing on the page; never from a saved page.
                    if !suggestions.isEmpty, !isReadOnly {
                        SuggestedTodosCard(note: note, suggestions: suggestions)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            MarkdownText(
                                markdown: shown,
                                onToggleTask: isLocked || note.isSaved ? nil : { toggleSummaryTask(line: $0) },
                                isTakenTask: note.isSaved ? nil : { text in
                                    TodoSuggestions.isTaken(text, states: TodoSuggestions.states(note.todoSuggestionsRaw), madeTitles: made.map(\.title))
                                }
                            )
                            if !isLocked {
                                Menu {
                                    Button { startEditingSummary() } label: { Label("Edit Summary", systemImage: "pencil") }
                                    Button { insertSummary() } label: { Label("Insert into Note", systemImage: "text.insert") }
                                    Button { copySummary() } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    Divider()
                                    Button(role: .destructive) { confirmDeleteSummary = true } label: { Label("Delete Summary", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.headline)
                                        .foregroundStyle(Color.brandNavy)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Summary Options")
                            }
                        }
                        if let model = note.summaryModel {
                            Text("Created with \(model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // What became of it: the to-dos made from this note, ticked and opened from here.
                    if !made.isEmpty {
                        MadeTodosList(todos: made)
                            .padding(.top, 4)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.brandSkyText)
                    Text(summarizeMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if !isLocked {
                        Button {
                            requestSummary()
                        } label: {
                            Label("Summarize", systemImage: "sparkles")
                        }
                        .buttonStyle(ChunkyButtonStyle())
                        .disabled(!canSummarize)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    /// Every kind asks for the model first, in the same place that warns about replacing a summary;
    /// a recording also picks its template there.
    private func requestSummary() {
        showSummaryOptions = true
    }

    private var summarizeMessage: String {
        note.isRecording
            ? "Let AI summarize this meeting – including decisions and action items."
            : note.isLink ? "Let AI summarize this page." : note.isImage ? "Let AI summarize this image." : note.isFile ? "Let AI summarize this file." : "Let AI summarize this note."
    }

    private func startEditingSummary() {
        tab = .summary
        if note.summary == nil { note.summary = "" }
        showSummaryEditor = true
    }

    /// Called when the summary editor closes: an emptied summary is removed.
    private func finishEditingSummary() {
        let text = (note.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            SummaryService.removeSummary(note)
        } else {
            note.summary = text
        }
        try? context.save()
    }

    /// Runs in the queue, like a transcript: it goes on when this screen closes.
    private func summarize(template: SummaryTemplate = .general, model: SummaryModel? = nil) {
        guard !isSummarizing else { return }
        tab = .summary
        // The editor hands its text to the note a moment after typing; make sure it has.
        focused = false
        editor.blur()
        let job = ProcessingService.Job.summary(note.id, template, model)
        let processing = processing
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            processing.enqueue(job)
        }
    }

    /// Runs in the queue: it goes on when this screen closes, and the text is locked meanwhile.
    private func enhance(model: SummaryModel) {
        guard !isEnhancing else { return }
        tab = .note
        // The editor hands its text to the note a moment after typing; make sure it has.
        focused = false
        editor.blur()
        let job = ProcessingService.Job.enhance(note.id, model)
        let processing = processing
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            processing.enqueue(job)
        }
    }

    private func insertSummary() {
        guard let summary = note.summary else { return }
        commitTyping()
        note.text = note.text.isEmpty ? summary : note.text + "\n\n" + summary
        note.updatedAt = Date()
        try? context.save()
    }

    private func copySummary() {
        guard let summary = note.summary else { return }
        UIPasteboard.general.string = summary
    }

    private func deleteSummary() {
        SummaryService.removeSummary(note)
        try? context.save()
    }

    private func toggleSummaryTask(line: Int) {
        SummaryTasks.toggleLine(line, of: note, in: context)
    }

    /// The note this to-do was taken from, while it is there.
    private var todoSource: Note? {
        guard let id = note.todoSourceID else { return nil }
        return allNotes.first { $0.id.uuidString == id && !$0.isDeleted }
    }

    private var addSubtaskButton: some View {
        Button {
            editor.perform(.appendChecklistItem)
        } label: {
            Label("Add Subtask", systemImage: "plus.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.brandTaskText)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// The note while dictating: live text in the accent color and a blinking cursor where it appears.
    private var dictationPreview: some View {
        let text = note.text
        let split = text.index(text.startIndex, offsetBy: min(dictationStart, text.count))
        let before = String(text[..<split])
        let after = String(text[split...])
        let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = !live.isEmpty && !before.isEmpty && before.last?.isWhitespace == false ? " " : ""

        return TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            let preview = Text("\(Text(before))\(Text(lead + live).foregroundStyle(Color.accentColor))\(Text("|").fontWeight(.bold).foregroundStyle(on ? Color.accentColor : Color.clear))\(Text(after))")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.top, 8)
                .id(NotePageScroll.followedID)
            preview
        }
    }

    /// The mic of the editor bar: a note that can be written to and has no job running.
    private var canDictate: Bool { processing.stages[note.id] == nil && !isLocked }

    private func toggleDictation() async {
        switch dictation.phase {
        case .idle:
            // The keyboard is not needed while dictating; the text appears where the cursor was.
            dictationStart = editor.cursorOffset
            liveText = ""
            focused = false
            editor.blur()
            dictation.onLiveText = { text in liveText = text }
            dictation.onStopRequested = { Task { await finishDictation() } }
            await dictation.start(title: note.title.isEmpty ? "Note" : note.title)
        case .recording:
            await finishDictation()
        case .polishing:
            break
        }
    }

    /// Stops recording and puts the final transcript of the whole recording into the note.
    private func finishDictation() async {
        guard let result = await dictation.stop() else { return }
        insertDictated(result.text)
        if let fileName = result.fileName {
            if note.text.isEmpty, note.title.isEmpty {
                // Nothing was recognized: no note, so no recording to keep either.
                AudioStore.delete(fileName)
            } else {
                note.audioFileNames.append(fileName)
            }
        }
        liveText = ""
        saveIfFilled()
        try? context.save()
    }

    /// Hands typing that is still on its way (see `NoteTextCoordinator.commit`) to the note. Called before the
    /// note's text is changed from here (a to-do ticked, an enhance undone): a commit still pending would otherwise
    /// write the older text back over that change. Changes made by the flush itself get what `onChange` gives them.
    private func commitTyping() {
        let old = note.text
        editor.blur()
        guard note.text != old else { return }
        note.updatedAt = Date()
        Todos.follow(note, from: old)
    }

    /// Stores a new note the first time it has a title or text.
    private func saveIfFilled() {
        guard note.modelContext == nil, !(note.text.isEmpty && note.title.isEmpty) else { return }
        context.insert(note)
        try? context.save()
    }

    /// Inserts the dictated text where the dictation started.
    private func insertDictated(_ dictated: String) {
        var text = note.text
        let index = text.index(text.startIndex, offsetBy: min(dictationStart, text.count))
        var piece = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if index > text.startIndex, let before = text[..<index].last, !before.isWhitespace {
            piece = " " + piece
        }
        if index < text.endIndex, let after = text[index...].first, !after.isWhitespace {
            piece += " "
        }
        text.insert(contentsOf: piece, at: index)
        note.text = text
        note.updatedAt = Date()
    }

    private var deletedBanner: some View {
        HStack(spacing: 12) {
            Label("In Recently Deleted", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Recover") { restore() }
                .buttonStyle(.bordered)
        }
        .foregroundStyle(Color.brandDangerText)
    }

    private func restore() {
        NoteStore.restore(note, in: context)
        onClose()
    }

    private var shareText: String { note.exportText }
}

/// Floating mic button: tap to dictate, tap again to stop. Shows the level and time while recording.
private struct DictationButton: View {
    let dictation: InlineDictation
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if dictation.phase == .recording {
                Text(dictation.recorder.elapsed.clockString)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.brandNavy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.appBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Look.hairline, lineWidth: Look.thinOutline))
                    .shadow(color: Color.brandNavy.opacity(0.12), radius: 8, y: 3)
                    .transition(Motion.slide(.move(edge: .trailing).combined(with: .opacity)))
            }
            ZStack {
                if dictation.phase == .recording {
                    Circle()
                        .fill(Color.red.opacity(0.25))
                        .frame(width: 64, height: 64)
                        .scaleEffect(Motion.isReduced ? 1 : 1 + CGFloat(dictation.recorder.levels.max() ?? 0) * 0.6)
                        .animation(.linear(duration: 0.1), value: dictation.recorder.levels.max() ?? 0)
                }
                FloatingActionButton(
                    systemImage: icon, label: label,
                    fill: dictation.phase == .recording ? Color.red : .brandSky,
                    action: action
                )
                if dictation.phase == .polishing {
                    ProgressView().tint(Color.brandNavy)
                }
            }
            .disabled(dictation.phase == .polishing)
        }
        .animation(.snappy, value: dictation.phase)
    }

    private var icon: String {
        switch dictation.phase {
        case .idle: "mic.fill"
        case .recording: "stop.fill"
        case .polishing: ""
        }
    }

    private var label: String {
        dictation.phase == .recording ? "Stop Dictation" : "Dictate"
    }
}

/// Shows what the dictation is doing: listening (live text appears in the note) or polishing the final text.
private struct DictationStatus: View {
    let dictation: InlineDictation

    var body: some View {
        HStack(spacing: 8) {
            switch dictation.phase {
            case .polishing:
                ProgressView().controlSize(.small)
                Text("Polishing…")
            default:
                if case .downloading(let progress) = ModelManager.shared.asr {
                    ProgressView(value: progress).tint(Color.brandSky).frame(width: 60)
                    Text("Downloading speech model…")
                } else {
                    switch dictation.live.phase {
                    case .idle, .preparing, .downloading:
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    case .running:
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                        Text("Listening…")
                    case .unavailable:
                        Image(systemName: "exclamationmark.circle")
                        Text("No live preview – the text appears when you stop")
                    }
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.accentColor)
    }
}

/// iOS: the whole note page scrolls, head included. The Mac keeps the head in place and scrolls only the tab.
private struct NotePageScroll: ViewModifier {
    static let followedID = "followed"
    /// The dictated text: the page stays with its end while it grows.
    let following: String
    let isEditing: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollDismissesKeyboard(.interactively)
                // The format bar lies over the end of the page; the cursor stays above it.
                .contentMargins(.bottom, isEditing ? 58 : 0, for: .scrollContent)
                .onChange(of: following) { proxy.scrollTo(Self.followedID, anchor: .bottom) }
        }
    }
}

/// The content of a tab: iOS scrolls it with the page, the Mac on its own.
private struct NoteTabScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack { content }
    }
}

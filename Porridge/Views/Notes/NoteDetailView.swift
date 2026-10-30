import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(ModelManager.self) private var models
    @State private var dictation = InlineDictation()
    /// Character offset where the current dictation starts; text before it is never changed.
    @State private var dictationStart = 0
    /// Live text of the running dictation; only shown, written to the note when the final text is ready.
    @State private var liveText = ""
    @State private var editor = NoteEditorController()
    @State private var isSummarizing = false
    @State private var summaryStatus: String?
    @State private var summaryError: String?
    @State private var tab = NoteTab.note
    @State private var confirmResummarize = false
    @State private var player = AudioPlayback()
    @State private var renamingSpeaker: Speaker?
    @State private var renameText = ""
    @State private var confirmDeleteAudio = false
    @State private var showMerge = false
    @State private var showSummaryEditor = false
    @State private var addingTag = false
    @State private var newTag = ""
    @FocusState private var focused: Bool

    /// The tabs of this note: a recording has a transcript and no text field of its own (unless it has text).
    private var opensOnSummary: Bool { note.isRecording || note.isLink }

    private var tabs: [(NoteTab, String)] {
        var list: [(NoteTab, String)] = []
        // Meetings and links open on their summary (first tab); they have no text field of their own unless they have text.
        if opensOnSummary { list.append((.summary, "Summary")) }
        if !opensOnSummary || !note.text.isEmpty { list.append((.note, "Note")) }
        if note.isRecording { list.append((.transcript, "Transcript")) }
        if note.isLink { list.append((.article, "Article")) }
        if !opensOnSummary { list.append((.summary, "Summary")) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if note.isDeleted { deletedBanner }

            if !note.isDeleted { tagRow }

            statusView

            if !note.speakers.isEmpty { speakerChips }

            TabSwitcher(selection: $tab, options: tabs.map { (value: $0.0, title: $0.1) })

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
                    NoteBodyEditor(text: $note.text, isEditable: !note.isDeleted, controller: editor)
                        .overlay(alignment: .topLeading) {
                            if note.text.isEmpty {
                                Text("Start typing or dictate …")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 3)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
        }
        .padding()
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .inlineNavigationTitle()
        .keyboardDoneBar(isShown: focused) { focused = false }
        .safeAreaInset(edge: .bottom) {
            if note.hasLocalAudio, tab != .note, !focused {
                PlayerBar(player: player) { confirmDeleteAudio = true }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .toolbar { toolbar }
        .overlay(alignment: .bottomTrailing) {
            if tab == .note, processing.stages[note.id] == nil, !note.isDeleted {
                DictationButton(dictation: dictation) {
                    Task { await toggleDictation() }
                }
                .padding(.trailing, 20)
                .padding(.bottom, editor.isEditing || focused ? 66 : 16)
                .animation(.snappy, value: editor.isEditing || focused)
            }
        }
        .onAppear {
            // Load the speech model right away so the first piece is transcribed without delay.
            Task { try? await ModelManager.shared.ensureASR() }
            if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
            tab = opensOnSummary ? .summary : .note
        }
        .onDisappear {
            player.stop()
            if dictation.phase == .recording {
                Task { await finishDictation() }
            }
            try? context.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .porridgeStopRecording)) { _ in
            if dictation.phase == .recording { Task { await finishDictation() } }
        }
        .onChange(of: note.text) {
            note.updatedAt = Date()
            saveIfFilled()
        }
        .onChange(of: note.title) {
            note.updatedAt = Date()
            saveIfFilled()
        }
        .sheet(isPresented: $showSummaryEditor, onDismiss: finishEditingSummary) {
            SummaryEditorSheet(text: Binding(get: { note.summary ?? "" }, set: { note.summary = $0 }))
        }
        .sheet(isPresented: $showMerge) {
            MergeNotesSheet(base: note) {
                // The recording may have been replaced by the joined one.
                player.stop()
                if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
                tab = .transcript
            }
        }
        .alert("Replace the current summary?", isPresented: $confirmResummarize) {
            Button("Cancel", role: .cancel) {}
            Button("Summarize Again", role: .destructive) { Task { await summarize() } }
        } message: {
            Text("Your edits to the summary are lost.")
        }
        .alert("Delete recording?", isPresented: $confirmDeleteAudio) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Recording", role: .destructive, action: deleteAudio)
        } message: {
            Text("The audio file is removed from this device. Transcript, speakers and summary stay.")
        }
        .alert("Rename Speaker", isPresented: .constant(renamingSpeaker != nil)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Save") { commitRename() }
        }
        .alert("New Tag", isPresented: $addingTag) {
            TextField("Tag", text: $newTag)
            Button("Add", action: addTag)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Summary Failed", isPresented: .constant(summaryError != nil)) {
            Button("OK") { summaryError = nil }
        } message: {
            Text(summaryError ?? "")
        }
        .alert("Dictation", isPresented: .constant(dictation.errorMessage != nil && dictation.phase == .idle)) {
            Button("OK") { dictation.dismissError() }
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: Binding(
                get: { note.title },
                set: {
                    note.title = $0
                    note.titleIsCustom = true
                }
            ), axis: .vertical)
            .font(.title2.weight(.bold))
            .foregroundStyle(Color.brandNavy)
            .focused($focused)
            .disabled(note.isDeleted)

            if let address = note.linkURL, let domain = note.domain {
                Link(destination: address) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(domain).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandLink)
                }
                .accessibilityLabel("Open \(domain)")
            }

            HStack(spacing: 8) {
                Text(note.createdAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                if note.isRecording, note.duration > 0 {
                    Text("·")
                    Text(note.duration.durationText)
                }
                if let input = note.inputName {
                    Text("·")
                    Text(input).lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let stage = processing.stages[note.id] {
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
                if note.hasLocalAudio {
                    Button("Detect Speakers Again") { processing.enqueue(.transcript(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                }
            }
            .flatPanel(.gray)
        } else if note.status == .failed {
            VStack(alignment: .leading, spacing: 12) {
                Label(note.errorMessage ?? "Transcription failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if note.isLink {
                    Button("Try Again") {
                        note.status = .recorded
                        processing.enqueue(.link(note.id, summarize: false))
                    }
                    .buttonStyle(ChunkyButtonStyle())
                } else if note.hasLocalAudio {
                    Button("Try Again") { processing.enqueue(.transcript(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                } else if AudioStore.exists(note.pendingAudioFileName) {
                    Button("Try Again") { processing.enqueue(.note(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                }
            }
            .flatPanel(.red)
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(note.speakers) { speaker in
                    Button {
                        renameText = speaker.name
                        renamingSpeaker = speaker
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.speaker(speaker.colorIndex)).frame(width: 10, height: 10)
                            Text(speaker.name).font(.subheadline.weight(.semibold))
                            Image(systemName: "pencil").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.brandNavy)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .chunkyPill(fill: Color.speaker(speaker.colorIndex))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Tags

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(note.tags, id: \.self) { tag in
                    let removable = note.labels.contains { $0.lowercased() == tag.lowercased() }
                    HStack(spacing: 6) {
                        Text("#\(tag)").font(.subheadline.weight(.semibold))
                        if removable {
                            Button { removeTag(tag) } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove Tag")
                        }
                    }
                    .foregroundStyle(Color.brandNavy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .chunkyPill(fill: .brandSky)
                }
                Button {
                    newTag = ""
                    addingTag = true
                } label: {
                    Label("Tag", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandNavy)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .chunkyPill(fill: .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Tag")
            }
            .padding(.bottom, 4)
        }
    }

    private func addTag() {
        let tag = Note.cleanTag(newTag)
        guard !tag.isEmpty, !note.tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
        note.labels.append(tag)
        try? context.save()
    }

    private func removeTag(_ tag: String) {
        note.labels.removeAll { $0.lowercased() == tag.lowercased() }
        try? context.save()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        BrandToolbarItem(placement: .primaryAction) {
            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .brandToolbarButton()
            .accessibilityLabel("Share")
        }
        BrandToolbarItem(placement: .primaryAction) {
            Menu {
                if note.isDeleted {
                    Button { restore() } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { note.isPinned.toggle(); try? context.save() } label: {
                        Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                    }
                    Button {
                        if note.summary == nil { Task { await summarize() } } else { confirmResummarize = true }
                    } label: {
                        Label(note.summary == nil ? "Summarize" : "Summarize Again", systemImage: "sparkles")
                    }
                    .disabled(isSummarizing || !canSummarize)
                    Button { startEditingSummary() } label: {
                        Label(note.summary == nil ? "Write Summary" : "Edit Summary", systemImage: "pencil")
                    }
                    .disabled(isSummarizing)
                    if note.hasLocalAudio {
                        Button { processing.enqueue(.transcript(note.id)) } label: {
                            Label("Transcribe Again", systemImage: "waveform")
                        }
                        .disabled(processing.stages[note.id] != nil)
                    }
                    if note.isLink {
                        Button {
                            note.status = .recorded
                            processing.enqueue(.link(note.id, summarize: false))
                        } label: {
                            Label("Load Page Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(processing.stages[note.id] != nil)
                    }
                    if !note.segments.isEmpty {
                        Button { Clipboard.copy(note.transcriptText()) } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }
                        Button { showMerge = true } label: {
                            Label("Merge with …", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(processing.stages[note.id] != nil || note.status != .ready)
                    }
                    MoveToFolderMenu(note: note)
                    if note.hasLocalAudio {
                        Button(role: .destructive) { confirmDeleteAudio = true } label: {
                            Label("Delete Recording", systemImage: "waveform.slash")
                        }
                    }
                    Divider()
                    Button(role: .destructive) { NoteStore.trash(note, in: context); onClose() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                BrandMenuLabel(title: "More", systemImage: "ellipsis")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
    }

    private var canSummarize: Bool {
        !(note.text.isEmpty && note.title.isEmpty && note.segments.isEmpty && (note.pageText ?? "").isEmpty)
    }

    // MARK: - Article

    private var articleTab: some View {
        ScrollView {
            if let text = note.pageText, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if processing.stages[note.id] != nil || note.pageText == nil, note.status != .failed {
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
        ScrollView {
            if segments.isEmpty {
                Text(note.status == .ready ? "No speech was detected." : "The transcript appears here once processing is done.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(segments) { segment in
                        SegmentRow(
                            segment: segment,
                            speaker: speakers.first { $0.id == segment.speakerId },
                            isActive: player.isPlaying && player.currentTime >= segment.start && player.currentTime < segment.end
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard note.hasLocalAudio else { return }
                            player.seek(to: segment.start)
                            player.play()
                        }
                        .contextMenu {
                            Button {
                                Clipboard.copy(segment.text)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            if speakers.count > 1 {
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
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            // Also teaches the voice under this name; earlier unnamed speakers get checked against it.
            note.speakers = VoiceProfiles.rename(speakerID: speaker.id, to: name, in: note.speakers, context: context)
            try? context.save()
            VoiceProfiles.rematchAllMeetings(context: context)
        }
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
        ScrollView {
            if isSummarizing {
                SummarizingCard(message: summarizeMessage, status: summaryStatus)
            } else if let summary = note.summary {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            MarkdownText(markdown: summary)
                            Menu {
                                Button { startEditingSummary() } label: { Label("Edit Summary", systemImage: "pencil") }
                                Button { insertSummary() } label: { Label("Insert into Note", systemImage: "text.insert") }
                                Button { copySummary() } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { confirmResummarize = true } label: { Label("Summarize Again", systemImage: "sparkles") }
                                Divider()
                                Button(role: .destructive) { deleteSummary() } label: { Label("Delete Summary", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.headline)
                                    .foregroundStyle(Color.brandNavy)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Summary Options")
                        }
                        if let model = note.summaryModel {
                            Text("Created with \(model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        confirmResummarize = true
                    } label: {
                        Label("Summarize Again", systemImage: "sparkles")
                    }
                    .buttonStyle(ChunkyButtonStyle())
                    .disabled(!canSummarize)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.brandSky)
                    Text(summarizeMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await summarize() }
                    } label: {
                        Label("Summarize", systemImage: "sparkles")
                    }
                    .buttonStyle(ChunkyButtonStyle())
                    .disabled(!canSummarize)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private var summarizeMessage: String {
        note.isRecording
            ? "Let AI summarize this meeting – including decisions and action items."
            : note.isLink ? "Let AI summarize this page." : "Let AI summarize this note."
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
            note.summary = nil
            note.summaryModel = nil
            note.summarizedAt = nil
        } else {
            note.summary = text
        }
        try? context.save()
    }

    private func summarize() async {
        guard !isSummarizing else { return }
        tab = .summary
        isSummarizing = true
        summaryStatus = nil
        defer {
            isSummarizing = false
            summaryStatus = nil
        }
        // The editor hands its text to the note a moment after typing; make sure it has.
        focused = false
        editor.blur()
        try? await Task.sleep(for: .milliseconds(150))
        do {
            try await SummaryService.summarize(note) { status in summaryStatus = status }
            try? context.save()
        } catch {
            summaryError = error.localizedDescription
        }
    }

    private func insertSummary() {
        guard let summary = note.summary else { return }
        note.text = note.text.isEmpty ? summary : note.text + "\n\n" + summary
        note.updatedAt = Date()
        try? context.save()
    }

    private func copySummary() {
        guard let summary = note.summary else { return }
        #if os(iOS)
        UIPasteboard.general.string = summary
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        #endif
    }

    private func deleteSummary() {
        note.summary = nil
        note.summaryModel = nil
        note.summarizedAt = nil
        try? context.save()
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
            ScrollViewReader { proxy in
                ScrollView {
                    Text("\(Text(before))\(Text(lead + live).foregroundStyle(Color.accentColor))\(Text("|").fontWeight(.bold).foregroundStyle(on ? Color.accentColor : Color.clear))\(Text(after))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .id("text")
                }
                .onChange(of: liveText) { proxy.scrollTo("text", anchor: .bottom) }
            }
        }
    }

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
        .foregroundStyle(.red)
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
                    .background(Color.white, in: Capsule())
                    .overlay(Capsule().strokeBorder(Look.hairline, lineWidth: Look.thinOutline))
                    .shadow(color: Color.brandNavy.opacity(0.12), radius: 8, y: 3)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            ZStack {
                if dictation.phase == .recording {
                    Circle()
                        .fill(Color.red.opacity(0.25))
                        .frame(width: 64, height: 64)
                        .scaleEffect(1 + CGFloat(dictation.recorder.levels.max() ?? 0) * 0.6)
                        .animation(.linear(duration: 0.1), value: dictation.recorder.levels.max() ?? 0)
                }
                FloatingActionButton(
                    systemImage: icon, label: label,
                    fill: dictation.phase == .recording ? Color(red: 1, green: 0.42, blue: 0.42) : .brandSky,
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
                Text("Polishing …")
            default:
                if case .downloading(let progress) = ModelManager.shared.asr {
                    ProgressView(value: progress).tint(Color.brandSky).frame(width: 60)
                    Text("Downloading speech model …")
                } else {
                    switch dictation.live.phase {
                    case .idle, .preparing, .downloading:
                        ProgressView().controlSize(.small)
                        Text("Starting …")
                    case .running:
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                        Text("Listening …")
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

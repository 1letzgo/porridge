import AVFoundation
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
    /// A note that was just created records right away.
    var startsRecording = false
    /// On a phone: the note has the app's own bar, with a back pill that calls this. Nil: the system's bar.
    var onBack: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(ModelManager.self) private var models
    @State private var dictation = InlineDictation()
    @State private var didStartRecording = false
    @State private var showExport = false
    @State private var isFetchingAudio = false
    @State private var fetchAudioError: String?
    /// Redraws when a recording arrived: the file on disk is not observed.
    @State private var fetchedAudio = 0
    @State private var showContinueRecording = false
    @State private var confirmContinueRecording = false
    /// Character offset where the current dictation starts; text before it is never changed.
    @State private var dictationStart = 0
    /// Live text of the running dictation; only shown, written to the note when the final text is ready.
    @State private var liveText = ""
    @State private var editor = NoteEditorController()
    @State private var tab = NoteTab.note
    @State private var confirmResummarize = false
    @State private var showSummaryOptions = false
    @State private var player = AudioPlayback()
    @State private var renamingSpeaker: Speaker?
    @State private var renameText = ""
    @State private var confirmDeleteAudio = false
    @State private var confirmDeleteSummary = false
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
        // The tab stays while it is open, even when its text was just cleared.
        if !opensOnSummary || !note.text.isEmpty || tab == .note { list.append((.note, "Note")) }
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
                    NoteBodyEditor(text: $note.text, isEditable: !note.isDeleted, controller: editor, placeholder: "Start typing or dictate…", growsWithText: true)
                }
            }
        }
        .padding()
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .modifier(NotePageScroll(following: liveText, isEditing: editor.isEditing))
        #if os(iOS)
        .overlay(alignment: .bottom) {
            if editor.isEditing, !note.isDeleted, tab == .note, dictation.phase == .idle {
                NoteKeyboardBar(controller: editor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        #endif
        .background(Color.appBackground)
        .inlineNavigationTitle()
        .keyboardDoneBar(isShown: focused) { focused = false }
        .safeAreaInset(edge: .bottom) {
            if note.hasLocalAudio, tab != .note, !focused {
                PlayerBar(player: player) { confirmDeleteAudio = true }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if fetchedAudio >= 0, canFetchAudio, tab != .note, !focused {
                fetchAudioBar
            }
        }
        .toolbar { toolbar }
        #if os(macOS)
        .focusedSceneValue(\.noteActions, NoteActions(
            isDeleted: note.isDeleted,
            isPinned: note.isPinned,
            hasSummary: note.summary != nil,
            canSummarize: !isSummarizing && canSummarize,
            canEditSummary: !isSummarizing,
            canTranscribe: note.hasLocalAudio && processing.stages[note.id] == nil,
            hasTranscript: !note.segments.isEmpty,
            togglePin: { note.isPinned.toggle(); try? context.save() },
            summarize: { requestSummary() },
            editSummary: { startEditingSummary() },
            transcribeAgain: { processing.enqueue(.transcript(note.id)) },
            copyTranscript: { Clipboard.copy(note.transcriptText()) },
            delete: { NoteStore.trash(note, in: context); onClose() },
            recover: { restore() }
        ))
        #endif
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let onBack {
                ChromeBar(title: barTitle, systemImage: barIcon, tint: barTint, onBack: onBack) {
                    shareAction
                    moreMenu
                }
                .padding(.bottom, Look.headerGap)
                .background(Color.appBackground)
            }
        }
        .toolbar(onBack == nil ? .automatic : .hidden, for: .navigationBar)
        #endif
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
            tab = opensOnSummary || isSummarizing ? .summary : .note
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
        .sheet(isPresented: $showSummaryOptions) {
            SummaryOptionsSheet(replacesSummary: note.summary != nil) { template, model in
                summarize(template: template, model: model)
            }
        }
        .alert("Replace Summary?", isPresented: $confirmResummarize) {
            Button("Cancel", role: .cancel) {}
            Button("Summarize Again", role: .destructive) { summarize() }
        } message: {
            Text("Your edits to the summary are lost.")
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
            Text(NextcloudSync.shared.isActive
                ? "The audio file is removed from all your devices and from Nextcloud. Transcript, speakers and summary stay."
                : "The audio file is removed from this device. Transcript, speakers and summary stay.")
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
                    .foregroundStyle(Color.brandLinkText)
                }
                .accessibilityLabel("Open \(domain)")
            }

            Text(metaLine)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// One text, so a long line wraps as a line and not column by column.
    private var metaLine: String {
        var parts = [note.createdAt.formatted(.dateTime.weekday(.wide).day().month().hour().minute())]
        if note.isRecording, note.duration > 0 { parts.append(note.duration.durationText) }
        if let input = note.inputName { parts.append(input) }
        return parts.joined(separator: " · ")
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
                if note.hasLocalAudio {
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
                } else if AudioStore.exists(note.pendingAudioFileName) {
                    Button("Try Again") { processing.enqueue(.note(note.id)) }
                        .buttonStyle(ChunkyButtonStyle())
                } else if note.hasLocalAudio {
                    Button("Try Again") { processing.enqueue(.transcript(note.id)) }
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
                            if AppSettings.isMe(speaker) { MeBadge() }
                            Image(systemName: "pencil").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.brandNavy)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .chunkyPill(fill: Color.speaker(speaker.colorIndex))
                    }
                    .buttonStyle(.plain)
                    .disabled(note.isDeleted)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Tags

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ProjectPills(assigned: note.projectIDs) { project in
                    Projects.toggle(project, on: note, in: context)
                }
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
                        .chunkyPill(fill: .gray)
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

    private var barTitle: String { note.isLink ? "Link" : note.isRecording ? "Meeting" : "Note" }
    private var barIcon: String { note.isLink ? "link" : note.isRecording ? "waveform" : "text.alignleft" }
    private var barTint: Color { note.isLink ? .brandLink : note.isRecording ? .brandNavy : .brandSky }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        BrandToolbarItem(placement: .primaryAction) { shareAction }
        BrandToolbarItem(placement: .primaryAction) { moreMenu.buttonStyle(.plain) }
    }

    @ViewBuilder
    private var shareAction: some View {
        if note.isRecording, !note.isLink {
            Button { showExport = true } label: {
                Label("Export", systemImage: "arrow.up.doc")
            }
            .brandToolbarButton()
            .accessibilityLabel("Export")
            .help("Export")
        } else {
            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .brandToolbarButton()
            .accessibilityLabel("Share")
            .help("Share")
        }
    }

    private var moreMenu: some View {
        Menu {
            if note.isDeleted {
                Button { restore() } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
            } else {
                Button { note.isPinned.toggle(); try? context.save() } label: {
                    Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                }
                Button {
                    requestSummary()
                } label: {
                    Label(note.summary == nil ? "Summarize" : "Summarize Again", systemImage: "sparkles")
                }
                .disabled(isSummarizing || !canSummarize)
                Button { startEditingSummary() } label: {
                    Label(note.summary == nil ? "Write Summary" : "Edit Summary", systemImage: "pencil")
                }
                .disabled(isSummarizing)
                Divider()
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
                if note.isRecording, !note.isLink {
                    Button {
                        if note.summary == nil { showContinueRecording = true } else { confirmContinueRecording = true }
                    } label: {
                        Label("Continue Recording", systemImage: "mic.badge.plus")
                    }
                    .disabled(!canContinueRecording)
                }
                if !note.segments.isEmpty {
                    Button { Clipboard.copy(note.transcriptText()) } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    Button { showMerge = true } label: {
                        Label("Merge with…", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(processing.stages[note.id] != nil || note.status != .ready)
                }
                Divider()
                if note.hasLocalAudio {
                    Button(role: .destructive) { confirmDeleteAudio = true } label: {
                        Label("Delete Recording", systemImage: "waveform.slash")
                    }
                }
                Button(role: .destructive) { NoteStore.trash(note, in: context); onClose() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            BrandMenuLabel(title: "More", systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
        .help("More")
    }

    /// A recording that is on another device could not be joined with the new part.
    private var canContinueRecording: Bool {
        processing.stages[note.id] == nil && note.status == .ready && note.pendingAudioFileName == nil
            && (note.audioFileName == nil || note.hasLocalAudio)
    }

    /// The recording is on Nextcloud and not here yet: it comes when asked for.
    private var canFetchAudio: Bool {
        note.audioFileName != nil && !note.hasLocalAudio && NextcloudSync.shared.isActive
    }

    private var fetchAudioBar: some View {
        VStack(spacing: 6) {
            Button {
                Task { await fetchAudio() }
            } label: {
                if isFetchingAudio {
                    ProgressView().tint(Color.brandNavy)
                } else {
                    Label("Download Recording", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(ChunkyButtonStyle())
            .disabled(isFetchingAudio)
            if let fetchAudioError {
                Text(fetchAudioError).font(.footnote).foregroundStyle(Color.brandDangerText)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func fetchAudio() async {
        guard let name = note.audioFileName else { return }
        isFetchingAudio = true
        fetchAudioError = nil
        defer { isFetchingAudio = false }
        do {
            try await NextcloudSync.shared.fetchRecording(name)
            fetchedAudio += 1
            player.load(AudioStore.url(for: name))
        } catch {
            fetchAudioError = error.localizedDescription
        }
    }

    private var isSummarizing: Bool { processing.summarizing.contains(note.id) }
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
                        SegmentRow(
                            segment: segment,
                            speaker: speakers.first { $0.id == segment.speakerId },
                            isActive: player.isPlaying && player.currentTime >= segment.start && player.currentTime < segment.end
                        )
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(note.hasLocalAudio ? .isButton : [])
                        .accessibilityHint(note.hasLocalAudio ? "Plays the recording from here." : "")
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
                            if speakers.count > 1, !note.isDeleted {
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
        NoteTabScroll {
            if isSummarizing {
                SummarizingCard(message: summarizeMessage, status: processing.stages[note.id], model: processing.summaryModels[note.id]?.label ?? SummaryService.modelLabel)
            } else if let summary = note.summary {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            MarkdownText(markdown: summary, onToggleTask: note.isDeleted || note.isLink ? nil : { toggleSummaryTask(line: $0) })
                            if !note.isDeleted {
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
                    if !note.isDeleted {
                        Button {
                            requestSummary()
                        } label: {
                            Label("Summarize Again", systemImage: "sparkles")
                        }
                        .buttonStyle(ChunkyButtonStyle())
                        .disabled(!canSummarize)
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
                    if !note.isDeleted {
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

    /// A recording asks for the model and the template, in the same place that warns about replacing a summary;
    /// a note or a link has nothing to choose.
    private func requestSummary() {
        if !note.segments.isEmpty {
            showSummaryOptions = true
        } else if note.summary == nil {
            summarize()
        } else {
            confirmResummarize = true
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

    private func toggleSummaryTask(line: Int) {
        SummaryTasks.toggleLine(line, of: note, in: context)
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
            #if os(iOS)
            preview
            #else
            ScrollViewReader { proxy in
                ScrollView { preview }
                    .onChange(of: liveText) { proxy.scrollTo(NotePageScroll.followedID, anchor: .bottom) }
            }
            #endif
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
        #if os(iOS)
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollDismissesKeyboard(.interactively)
                // The format bar lies over the end of the page; the cursor stays above it.
                .contentMargins(.bottom, isEditing ? 58 : 0, for: .scrollContent)
                .onChange(of: following) { proxy.scrollTo(Self.followedID, anchor: .bottom) }
        }
        #else
        content
        #endif
    }
}

/// The content of a tab: iOS scrolls it with the page, the Mac on its own.
private struct NoteTabScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        VStack { content }
        #else
        ScrollView { content }
        #endif
    }
}

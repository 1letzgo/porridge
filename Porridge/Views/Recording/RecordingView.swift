import SwiftUI

/// Full-screen meeting recorder with live transcript.
struct RecordingView: View {
    /// The appointment the meeting is named after.
    var title: String?
    /// The meeting this recording is added to.
    var continues: UUID?
    var onFinish: (RecordingResult, [String], String, [RecordingNote]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var models
    @State private var recorder = AudioRecorder()
    @State private var live = LiveTranscriber()
    @State private var speakerNames = ["Speaker 1", "Speaker 2"]
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @State private var finished = false
    @State private var notes: [RecordingNote] = []
    @State private var noteDraft = ""
    /// Keeps the meeting if the app does not get to the end of it.
    @State private var journal: RecordingJournal?
    @FocusState private var writingNote: Bool

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                header

                Text(recorder.elapsed.clockString)
                    .font(.system(size: writingNote ? 28 : 60, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                    .contentTransition(.numericText())

                // While a note is being typed the keyboard needs the room.
                if !writingNote { meters }

                LiveTranscriptCard(live: live, isPaused: recorder.isPaused)
                    .onTapGesture { writingNote = false }

                noteList

                noteField

                if !writingNote, let hint {
                    Text(hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if !writingNote { recordingButtons }
            }
            .padding()
            .animation(.snappy, value: writingNote)
        }
        .task { await start() }
        .onAppear {
            recorder.onInterrupted = { finish() }
            recorder.pausesForCalls = true
            recorder.onPauseChanged = { LiveRecording.setPaused(recorder.isPaused, elapsed: recorder.elapsed) }
        }
        .onChange(of: models.asr) { live.observeDownload(models.asr) }
        .onChange(of: notes) { journal?.setNotes(notes) }
        .onReceive(NotificationCenter.default.publisher(for: .porridgeStopRecording)) { _ in finish() }
        .alert("Discard Recording?", isPresented: $confirmDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                recorder.cancel()
                live.cancel()
                journal?.finish()
                LiveRecording.end()
                dismiss()
            }
        }
        .alert("Can't Record", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        HStack {
            Button {
                confirmDiscard = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.appSecondaryBackground, in: Circle())
            }
            .accessibilityLabel("Discard")

            Spacer()

            Label(recorder.isPausedForCall ? "Paused for Call" : recorder.isPaused ? "Paused" : inputLabel, systemImage: recorder.isPaused ? "pause.fill" : recorder.isExternal ? "mic.badge.plus" : "mic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.brandSky.opacity(0.14), in: Capsule())
        }
    }

    /// The notes so far as short bubbles, newest at the bottom.
    @ViewBuilder
    private var noteList: some View {
        if !notes.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(notes) { note in
                            noteBubble(note).id(note.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxHeight: writingNote ? 88 : 132)
                .fixedSize(horizontal: false, vertical: notes.count < 3)
                .onChange(of: notes.count) {
                    if let last = notes.last { withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func noteBubble(_ note: RecordingNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(note.at.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(note.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.brandSky.opacity(0.16), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .padding(.leading, 48)
        .contextMenu {
            Button(role: .destructive) {
                notes.removeAll { $0.id == note.id }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var noteField: some View {
        HStack(spacing: 10) {
            TextField("Add a note…", text: $noteDraft)
                .focused($writingNote)
                .submitLabel(.send)
                .onSubmit(addNote)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.appBackground, in: RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Look.buttonRadius, style: .continuous)
                        .strokeBorder(Look.hairline, lineWidth: Look.outline)
                )
            Button(action: addNote) {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.brandSky, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add Note")
        }
    }

    /// Return with an empty field closes the keyboard, which brings the stop button back.
    private func addNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            writingNote = false
            return
        }
        notes.append(RecordingNote(at: recorder.elapsed, text: text))
        noteDraft = ""
        writingNote = true
    }

    private var inputLabel: String {
        guard !recorder.inputName.isEmpty else { return "Microphone" }
        return recorder.isSplitStereo ? "\(recorder.inputName) · 2 channels" : recorder.inputName
    }

    @ViewBuilder
    private var meters: some View {
        if recorder.isSplitStereo {
            VStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { index in
                    HStack(spacing: 12) {
                        Circle().fill(Color.speaker(index)).frame(width: 12, height: 12)
                        TextField("Name", text: $speakerNames[index])
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .submitLabel(.done)
                        LevelBar(level: index < recorder.levels.count ? recorder.levels[index] : 0)
                            .frame(width: 110)
                    }
                    .padding(12)
                    .chunkyCard(padding: 0)
                }
            }
        } else {
            LevelBar(level: recorder.levels.max() ?? 0)
                .frame(height: 14)
                .padding(.horizontal, 40)
        }
    }

    private var hint: String? {
        if recorder.isSplitStereo {
            return "Each microphone is assigned to one speaker. You can rename them now or later."
        }
        if recorder.isExternal {
            return "Tip: switch your DJI receiver to stereo to separate speakers per microphone."
        }
        return nil
    }

    private var recordingButtons: some View {
        HStack(spacing: 24) {
            pauseButton
            stopButton
        }
        .padding(.bottom, 8)
    }

    private var pauseButton: some View {
        Button(action: togglePause) {
            Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .brandSurface(Circle())
        }
        .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
        .disabled(!recorder.isRecording || recorder.isPausedForCall)
    }

    private var stopButton: some View {
        Button {
            finish()
        } label: {
            ZStack {
                Circle().fill(Color.appBackground).brandSurface(Circle())
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 30, height: 30)
            }
            .frame(width: 84, height: 84)
        }
        .accessibilityLabel("Stop recording")
        .disabled(!recorder.isRecording)
    }

    private func togglePause() {
        // It goes on by itself when the call ends.
        guard !recorder.isPausedForCall else { return }
        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        LiveRecording.setPaused(recorder.isPaused, elapsed: recorder.elapsed)
    }

    private func start() async {
        guard await AudioRecorder.requestPermission() else {
            errorMessage = "Please allow microphone access in Settings."
            return
        }
        // The task runs again when the presentation settles; a second start would leave the first file behind.
        guard !recorder.isRecording, !finished else { return }
        do {
            let journal = RecordingJournal(title: title, continues: continues)
            self.journal = journal
            let feed = live.feed
            recorder.onBuffer = { buffer in
                feed(buffer)
                journal.append(buffer)
            }
            try recorder.start()
            journal.setUnfinishedFile(recorder.fileName)
            // Keeps recording visible on the Lock Screen; recording itself continues via the audio background mode.
            LiveRecording.start(kind: .meeting, title: "Meeting", onTogglePause: { togglePause() }) { finish() }
            await live.start(language: AppSettings.language)
        } catch {
            journal?.finish()
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        guard !finished, let result = recorder.stop() else { return }
        finished = true
        let names = speakerNames.enumerated().map { index, name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Speaker \(index + 1)" : trimmed
        }
        let liveText = live.text
        LiveRecording.end()
        live.cancel()
        var written = notes
        let unsent = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unsent.isEmpty { written.append(RecordingNote(at: result.duration, text: unsent)) }
        onFinish(result, names, liveText, written)
        journal?.finish()
        dismiss()
    }
}

/// Scrolling live transcript, newest text at the bottom.
struct LiveTranscriptCard: View {
    let live: LiveTranscriber
    var isPaused = false
    var minHeight: CGFloat = 120
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading) {
                    content
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(minHeight: minHeight)
            .chunkyCard(padding: 0)
            .onChange(of: live.text) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch live.phase {
        case .idle, .preparing:
            Label("Starting live transcription…", systemImage: "waveform")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading speech model (one time) …")
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .tint(Color.brandSky)
            }
        case .unavailable:
            Label("Live transcription unavailable. The transcript is created after recording.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .running:
            if live.text.isEmpty {
                Label(isPaused ? "Paused" : "Listening…", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: !isPaused)
            } else {
                paragraphs
            }
        }
    }
}

extension LiveTranscriptCard {
    /// Running text broken into short paragraphs; sentences that are not confirmed yet are dimmed.
    fileprivate var paragraphs: some View {
        let confirmedCount = Paragraphs.sentences(live.confirmed).count
        let all = Paragraphs.sentences([live.confirmed, live.volatile].filter { !$0.isEmpty }.joined(separator: " "))
        let groups = Paragraphs.group(all.enumerated().map { (text: $0.element, flag: $0.offset >= confirmedCount) })
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                group.enumerated().reduce(Text("")) { result, item in
                    let piece = Text((item.offset == 0 ? "" : " ") + item.element.text)
                        .foregroundStyle(item.element.flag ? Color.secondary : Color.primary)
                    return result + piece
                }
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Look.hairline)
                Capsule()
                    .fill(Color.brandSky)
                    .frame(width: max(8, proxy.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(minHeight: 10, maxHeight: 14)
    }
}

import SwiftUI

/// Full-screen meeting recorder with live transcript.
struct RecordingView: View {
    var onFinish: (RecordingResult, [String], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var models
    @State private var recorder = AudioRecorder()
    @State private var live = LiveTranscriber()
    @State private var speakerNames = ["Speaker 1", "Speaker 2"]
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                header

                Text(recorder.elapsed.clockString)
                    .font(.system(size: 60, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                meters

                LiveTranscriptCard(live: live)

                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                stopButton
            }
            .padding()
        }
        .task { await start() }
        .onAppear {
            recorder.onInterrupted = { finish() }
        }
        .onChange(of: models.asr) { live.observeDownload(models.asr) }
        .onReceive(NotificationCenter.default.publisher(for: .porridgeStopRecording)) { _ in finish() }
        .alert("Discard recording?", isPresented: $confirmDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                recorder.cancel()
                live.cancel()
                LiveRecording.end()
                dismiss()
            }
        }
        .alert("Can't record", isPresented: .constant(errorMessage != nil)) {
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

            Label(inputLabel, systemImage: recorder.isExternal ? "mic.badge.plus" : "mic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.brandSky.opacity(0.14), in: Capsule())
        }
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
        .padding(.bottom, 8)
    }

    private func start() async {
        guard await AudioRecorder.requestPermission() else {
            errorMessage = "Please allow microphone access in Settings."
            return
        }
        do {
            recorder.onBuffer = live.feed
            try recorder.start()
            // Keeps recording visible on the Lock Screen; recording itself continues via the audio background mode.
            LiveRecording.start(kind: .meeting, title: "Meeting") { finish() }
            await live.start(language: AppSettings.language)
        } catch {
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
        onFinish(result, names, liveText)
        dismiss()
    }
}

/// Scrolling live transcript, newest text at the bottom.
struct LiveTranscriptCard: View {
    let live: LiveTranscriber
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
            Label("Starting live transcription …", systemImage: "waveform")
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
                Label("Listening …", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative)
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

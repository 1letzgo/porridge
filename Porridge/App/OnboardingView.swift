import AVFoundation
import SwiftUI

/// First-launch wizard: welcome, microphone access, choose the speech model and download it.
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(ModelManager.self) private var models
    @AppStorage(AppSettings.speechEngineKey) private var engine = SpeechEngine.parakeet
    @AppStorage(AppSettings.languageKey) private var language = "auto"
    @AppStorage(AppSettings.speakerDetectionKey) private var speakerDetection = true

    @State private var step = 0
    @State private var micGranted: Bool?
    @State private var isDownloading = false

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0...lastStep, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.brandSky : Look.hairline)
                        .frame(height: 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                case 2: modelStep
                default: ready
                }
            }
            .frame(maxWidth: 520, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            .id(step)

            Button(action: next) {
                Text(buttonTitle)
            }
            .buttonStyle(ChunkyButtonStyle())
            .disabled(isDownloading)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appGroupedBackground)
        .interactiveDismissDisabled()
        .animation(.snappy, value: step)
        .task { await models.refreshASR() }
    }

    // MARK: - Steps

    private var welcome: some View {
        page(icon: "text.bubble.fill", title: "Welcome to Porridge",
             text: "Record meetings and notes. Porridge turns speech into text right on your device, with speaker names.") {
            EmptyView()
        }
    }

    private var microphone: some View {
        page(icon: "mic.fill", title: "Microphone",
             text: "Porridge needs the microphone to record. Audio stays on your device. DJI Mic receivers and other USB microphones work too.") {
            if let micGranted {
                Label(micGranted ? "Access granted" : "Access denied – you can change this in Settings.",
                      systemImage: micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(micGranted ? Color.brandSky : .orange)
                    .font(.headline)
            }
        }
    }

    private var modelStep: some View {
        page(icon: "arrow.down.circle.fill", title: "Speech Model",
             text: "Choose the model that turns speech into text. It runs completely on your device and is downloaded once, preferably over Wi‑Fi.") {
            VStack(spacing: 12) {
                if AppleSpeech.isSupported {
                    engineCard(.parakeet, title: "Parakeet v3", detail: "Most accurate · 25 languages · about 480 MB")
                    engineCard(.apple, title: "Apple (built in)", detail: "Built into iOS · small language pack")
                }
                Toggle("Detect speakers (about 30 MB)", isOn: $speakerDetection)
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                modelStatus
            }
        }
    }

    private var ready: some View {
        page(icon: "checkmark.seal.fill", title: "All Set",
             text: "Record a note or a meeting. Everything can be changed later in Settings.") {
            EmptyView()
        }
    }

    // MARK: - Pieces

    private func page<Content: View>(icon: String, title: String, text: String,
                                      @ViewBuilder extra: () -> Content) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(Color.brandSky)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            extra()
            Spacer(minLength: 20)
        }
    }

    private func engineCard(_ option: SpeechEngine, title: String, detail: String) -> some View {
        Button {
            engine = option
            Task { await models.refreshASR() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: engine == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(engine == option ? Color.brandSky : .secondary)
                    .font(.title3)
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(engine == option ? Color.brandSky : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch models.asr {
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading … \(Int(progress * 100)) %").font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            HStack { ProgressView(); Text("Preparing …").font(.caption).foregroundStyle(.secondary) }
        case .ready, .installed:
            Label("Model is on your device", systemImage: "checkmark.circle.fill").foregroundStyle(Color.brandSky)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
        case .notInstalled:
            EmptyView()
        }
    }

    private var buttonTitle: String {
        switch step {
        case 0: "Get Started"
        case 1: micGranted == nil ? "Allow Microphone" : "Continue"
        case 2:
            if isDownloading { "Downloading …" }
            else if case .failed = models.asr { "Try Again" }
            else if models.asr == .ready || models.asr == .installed { "Continue" }
            else { "Download & Continue" }
        default: "Start Recording"
        }
    }

    private func next() {
        switch step {
        case 1 where micGranted == nil:
            Task { micGranted = await AudioRecorder.requestPermission() }
        case 2:
            Task { await downloadModels() }
        case lastStep:
            onFinish()
        default:
            step += 1
        }
    }

    private func downloadModels() async {
        if models.asr == .ready || models.asr == .installed, !speakerDetection || models.diarizer != .notInstalled {
            step += 1
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        do {
            try await models.ensureASR()
            if speakerDetection { try? await models.ensureDiarizer() }
            step += 1
        } catch {
            // The error is shown in the status area; the button turns into "Try Again".
        }
    }
}

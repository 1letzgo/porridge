import AVFoundation
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

struct SettingsView: View {
    @Environment(ModelManager.self) private var models
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \VoiceProfile.name) private var voices: [VoiceProfile]

    @AppStorage(AppSettings.languageKey) private var language = "auto"
    @AppStorage(AppSettings.speechEngineKey) private var engine = SpeechEngine.parakeet
    @AppStorage(AppSettings.speakerDetectionKey) private var speakerDetection = true
    @AppStorage(AppSettings.voiceRecognitionKey) private var voiceRecognition = true
    @AppStorage(AppSettings.localModelKey) private var localModel = LocalModel.qwen3
    @AppStorage(AppSettings.billingKey) private var billing: SummaryBilling = .local
    @AppStorage(AppSettings.providerKey) private var provider = AIProvider.openRouter
    @AppStorage(AppSettings.customBaseURLKey) private var customBaseURL = ""
    @AppStorage(AppSettings.myNameKey) private var myName = ""


    @State private var apiKey = AIProvider.current.apiKey
    @State private var modelText = AIProvider.current.model
    /// Models the provider reports for the entered key.
    @State private var fetchedModels: [String] = []
    @State private var inputDescription = ""
    @State private var renamingVoice: VoiceProfile?
    @State private var voiceName = ""
    @State private var forgettingVoice: VoiceProfile?
    @State private var pendingDeletion: ModelKind?
    #if os(macOS)
    @AppStorage(DictationSettings.enabledKey) private var dictationEnabled = true
    @AppStorage(DictationSettings.modeKey) private var dictationMode = DictationMode.hold
    @AppStorage(DictationSettings.soundsKey) private var dictationSounds = true
    @AppStorage(DictationSettings.keepClipboardKey) private var keepClipboard = true
    @AppStorage(DictationSettings.keyLabelKey) private var shortcutLabel = "Right ⌥"
    @AppStorage(DictationSettings.modifiersKey) private var shortcutModifiers = 0
    /// Bumped when the app comes to the front, so the permission rows re-read the system state.
    @State private var permissionTick = 0
    #endif
    @State private var modelError: String?
    @State private var showPlaud = false

    /// A downloaded model that can be deleted.
    private enum ModelKind: Identifiable {
        case speech
        case speakers
        case summary(LocalModel)

        var id: String {
            switch self {
            case .speech: "speech"
            case .speakers: "speakers"
            case .summary(let model): "summary.\(model.rawValue)"
            }
        }

        var name: String {
            switch self {
            case .speech: "Parakeet TDT v3"
            case .speakers: "Speaker Detection"
            case .summary(let model): model.displayName
            }
        }
    }

    /// Pushed onto the list's navigation stack (iOS): the system back button closes it, no own stack or Done button.
    var isPushed = false

    /// The Settings window of the Mac has no bar of its own above the content: give the first section air.
    private var settingsTopPadding: CGFloat {
        #if os(macOS)
        20
        #else
        4
        #endif
    }

    var body: some View {
        if isPushed {
            page
        } else {
            NavigationStack {
                page.toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if isPushed {
                ChromeBar(title: "Settings", systemImage: "gearshape.fill", onBack: { dismiss() })
                    .padding(.bottom, Look.headerGap)
            }
            #endif
            ScrollView {
                VStack(spacing: 32) { cards }
                    .padding(.horizontal, 20)
                    .padding(.top, settingsTopPadding)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color.appBackground)
        .brandNavigationTitle("Settings")
        #if os(iOS)
        // Pushed: our own bar (ChromeBar) replaces the system one.
        .toolbar(isPushed ? .hidden : .automatic, for: .navigationBar)
        #endif
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionTick += 1
        }
        #endif
        .onAppear {
            refreshInput()
            models.refreshLLM()
            fixLocalModelSelection()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { refreshInput() }
        }
        #endif
        .alert(
            "Delete \(pendingDeletion?.name ?? "model")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let kind = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    switch kind {
                    case .speech: await models.deleteASR()
                    case .speakers: await models.deleteDiarizer()
                    case .summary(let model): await models.deleteLLM(model)
                    }
                }
            }
        } message: {
            Text("You can download it again at any time.")
        }
        .alert("Rename Voice", isPresented: Binding(get: { renamingVoice != nil }, set: { if !$0 { renamingVoice = nil } })) {
            TextField("Name", text: $voiceName)
            Button("Cancel", role: .cancel) { renamingVoice = nil }
            Button("Save") {
                let name = voiceName.trimmingCharacters(in: .whitespaces)
                if let voice = renamingVoice, !name.isEmpty {
                    VoiceProfiles.rename(voice, to: name, context: context)
                }
                renamingVoice = nil
            }
        }
        .alert(
            "Forget this voice?",
            isPresented: Binding(get: { forgettingVoice != nil }, set: { if !$0 { forgettingVoice = nil } })
        ) {
            Button("Cancel", role: .cancel) { forgettingVoice = nil }
            Button("Forget Voice", role: .destructive) {
                if let voice = forgettingVoice { VoiceProfiles.delete(voice, context: context) }
                forgettingVoice = nil
            }
        } message: {
            Text("Names already given in meetings stay.")
        }
        .sheet(isPresented: $showPlaud) {
            PlaudImportSheet { audio in
                PlaudImporter.addNote(audio, context: context, processing: processing)
            }
        }
        .alert("Download Failed", isPresented: Binding(get: { modelError != nil }, set: { if !$0 { modelError = nil } })) {
            Button("OK") { modelError = nil }
        } message: {
            Text(modelError ?? "")
        }
        .onChange(of: models.llm) {
            reportFailure(in: Array(models.llm.values))
            fixLocalModelSelection()
        }
        .onChange(of: models.asr) { reportFailure(in: [models.asr]) }
        .onChange(of: models.diarizer) { reportFailure(in: [models.diarizer]) }
        .onChange(of: language) { Task { await models.refreshASR() } }
        .onChange(of: engine) { Task { await models.refreshASR() } }
        .onChange(of: provider) {
            apiKey = provider.apiKey
            modelText = provider.model
            fetchedModels = []
        }
    }

    /// Order: what happens to a recording (transcription, speakers, summary), the cloud service if
    /// summaries use it, then imports, sync and about. Transcription always runs on the device.
    @ViewBuilder
    private var cards: some View {
        #if os(macOS)
        dictationCard
        #endif
        youCard
        transcriptionCard
        speakersCard
        summaryCard
        if billing == .byok {
            cloudCard
        }
        importCard
        iCloudCard
        aboutCard
    }


    // MARK: - Cards

    /// Who the user is: their tasks go under "Mine", and the summaries name them.
    private var youCard: some View {
        SettingsCard(title: "You", footer: "Tasks given to this name show under Mine. Separate other spellings with commas, e.g. “Anna, Anna Berg”.") {
            TextField("Your Name", text: $myName)
                .textContentType(.name)
                .autocorrectionDisabled()
                .brandField()
        }
    }

    private var transcriptionCard: some View {
        SettingsCard(title: "Transcription") {
            if SpeechEngine.available.count > 1 {
                TabSwitcher(selection: $engine, options: SpeechEngine.available.map { (value: $0, title: $0.shortLabel) })
                    .padding(.bottom, 2)
            }

            switch AppSettings.speechEngine {
            case .apple:
                ModelRow(title: "Apple Speech", subtitle: "Built into the system · language pack only", state: models.asr) {
                    Task { try? await models.ensureLocalASR() }
                }
            case .parakeet:
                ModelRow(
                    title: "Parakeet TDT v3", subtitle: "Most accurate · 25 languages · approx. 480 MB",
                    state: models.asr, onDelete: { pendingDeletion = .speech }
                ) {
                    Task { try? await models.ensureLocalASR() }
                }
            }
            Text("Recordings are transcribed on this device; audio never leaves it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CardDivider()
            MenuRow(
                title: "Language",
                selection: $language,
                options: AppSettings.languages.map { (value: $0.code, title: $0.name) }
            )
            CardDivider()
            ValueRow(title: "Microphone", value: inputDescription)
        }
    }

    /// Who said what: speaker detection with its model, then known voices.
    private var speakersCard: some View {
        SettingsCard(title: "Speakers") {
            Toggle("Detect Speakers", isOn: $speakerDetection)
                .font(.body)
                .tint(Color.brandSky)
            if speakerDetection {
                ModelRow(
                    title: "Speaker Model", subtitle: "pyannote · on this device · approx. 30 MB", state: models.diarizer,
                    onDelete: { pendingDeletion = .speakers }
                ) {
                    Task { try? await models.ensureDiarizer() }
                }
                CardDivider()
                Toggle("Recognize Known Voices", isOn: $voiceRecognition)
                    .font(.body)
                    .tint(Color.brandSky)
                ForEach(voices) { voice in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name).font(.body)
                            Text("\(voice.seconds.clockString) of speech")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            voiceName = voice.name
                            renamingVoice = voice
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Rename")
                        Button {
                            forgettingVoice = voice
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .accessibilityLabel("Forget Voice")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var importCard: some View {
        SettingsCard(title: "Import") {
            HStack {
                Text("Plaud Recordings").font(.body)
                Spacer(minLength: 12)
                Button("Open") { showPlaud = true }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    private var summaryCard: some View {
        SettingsCard(title: "AI Summary") {
            TabSwitcher(selection: $billing, options: SummaryBilling.allCases.map { (value: $0, title: $0.label) })
                .padding(.bottom, 4)

            switch billing {
            case .local:
                // Only models that are on the device can be chosen.
                if downloadedModels.isEmpty {
                    ValueRow(title: "Summary Model", value: "None downloaded")
                } else {
                    MenuRow(
                        title: "Summary Model",
                        selection: $localModel,
                        options: downloadedModels.map { (value: $0, title: $0.displayName) }
                    )
                }
                ForEach(LocalModel.allCases) { model in
                    ModelRow(
                        title: model.displayName, subtitle: "Summaries on your device · \(model.sizeText)",
                        state: models.llmState(model),
                        onDelete: { pendingDeletion = .summary(model) }
                    ) {
                        Task { await models.downloadLLM(model) }
                    }
                }
            case .byok:
                if provider != .custom {
                    MenuRow(title: "Model", selection: modelBinding, options: modelOptions)
                        .task(id: "\(provider.rawValue)|\(apiKey)|\(customBaseURL)") { await loadModels() }
                }
                TextField("Model ID", text: modelBinding)
                    .font(.footnote.monospaced())
                    .plainFieldStyle()
                    .brandField()
            }
        }
    }

    private var downloadedModels: [LocalModel] {
        LocalModel.allCases.filter { models.llmState($0) == .installed || models.llmState($0) == .ready }
    }

    /// The chosen summary model must be one that is downloaded.
    private func fixLocalModelSelection() {
        let downloaded = downloadedModels
        if let first = downloaded.first, !downloaded.contains(localModel) {
            localModel = first
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { modelText },
            set: {
                modelText = $0
                provider.model = $0
            }
        )
    }

    private var modelOptions: [(value: String, title: String)] {
        var options = fetchedModels.isEmpty
            ? provider.suggestedModels.map { (value: $0.id, title: $0.name) }
            : fetchedModels.map { (value: $0, title: $0) }
        if !modelText.isEmpty, !options.contains(where: { $0.value == modelText }) {
            options.append((value: modelText, title: modelText))
        }
        return options
    }

    /// Asks the provider which models this key can use; picks a sensible one if the current choice is not offered.
    private func loadModels() async {
        fetchedModels = []
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard billing == .byok, provider.canListModels, !key.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled,
              let list = try? await CloudLLM.models(provider: provider, apiKey: key), !list.isEmpty else { return }
        fetchedModels = list
        if !list.contains(modelText) {
            let preferred = ["haiku", "flash", "mini", "luna", "small"]
            let choice = list.first { id in preferred.contains { id.lowercased().contains($0) } } ?? list[0]
            modelBinding.wrappedValue = choice
        }
    }

    /// The service with the user's own key; shown when summaries use the cloud.
    private var cloudCard: some View {
        SettingsCard(
            title: "Cloud Service",
            footer: "Used for summaries. The key is stored in your iCloud Keychain."
        ) {
            MenuRow(
                title: "Provider",
                selection: $provider,
                options: AIProvider.allCases.map { (value: $0, title: $0.label) }
            )
            if provider == .custom {
                TextField("Server address, e.g. http://192.168.1.5:11434/v1", text: $customBaseURL)
                    .urlFieldStyle()
                    .brandField()
            }
            SecureField(provider.requiresKey ? "\(provider.label) API Key" : "API Key (optional)", text: $apiKey)
                .secretFieldStyle()
                .brandField()
                .onChange(of: apiKey) {
                    Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keyAccount)
                }
        }
    }

    private var iCloudCard: some View {
        let available = FileManager.default.ubiquityIdentityToken != nil
        return SettingsCard(title: "iCloud") {
            Label(
                available ? "Notes are synced" : "Not signed in to iCloud",
                systemImage: available ? "checkmark.icloud.fill" : "xmark.icloud"
            )
            .font(.body)
            .foregroundStyle(available ? Color.accentColor : Color.accentColor.opacity(0.6))
        }
    }

    private var aboutCard: some View {
        SettingsCard(
            title: "About",
            footer: "Speech recognition: FluidAudio · NVIDIA Parakeet (CC-BY-4.0) · pyannote"
        ) {
            ValueRow(
                title: "Version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
            )
            #if os(macOS)
            updateRow
            #endif
            CardDivider()
            AcknowledgementsRow()
        }
    }

    #if os(macOS)
    /// Newer versions come as GitHub releases; the app looks for them by itself and on request.
    private var updateRow: some View {
        let update = AppUpdate.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updates").font(.body)
                Spacer(minLength: 12)
                if let release = update.available {
                    Button("Download \(release.version)") { update.download() }
                        .buttonStyle(PillButtonStyle())
                } else {
                    Button(update.checking ? "Checking…" : "Check Now") {
                        Task { await update.check(manual: true) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(update.checking)
                }
            }
            if let result = update.lastResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif

    /// A failed download or load is shown as a warning, not only as small text in the row.
    private func reportFailure(in states: [ModelManager.State]) {
        for state in states {
            if case .failed(let message) = state {
                modelError = message
                return
            }
        }
    }

    /// Shows which microphone would be used right now (e.g. a plugged-in DJI receiver).
    private func refreshInput() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let isRecording = RecordingCenter.stop != nil
        if !isRecording {
            // The system only lists external inputs once the session is set up for recording.
            try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            try? session.setActive(true)
        }
        let inputs = session.availableInputs ?? []
        let current = session.currentRoute.inputs.first
        let input = inputs.first { $0.portType != .builtInMic } ?? current ?? inputs.first
        if let input {
            let channels = input.uid == current?.uid ? session.inputNumberOfChannels : (input.channels?.count ?? 1)
            inputDescription = channels > 1 ? "\(input.portName) · \(channels) channels" : input.portName
        } else {
            inputDescription = "Built-in Microphone"
        }
        if !isRecording {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #else
        inputDescription = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Microphone"
        #endif
    }
}

// MARK: - Building blocks

/// Settings group in the style of the list: a section head with a hairline, rows on the white page.
private struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The same section head as in the list: bold title over a hairline.
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Rectangle().fill(Look.hairline).frame(height: 0.5)
            }
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .foregroundStyle(.primary)

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Look.hairline)
            .frame(height: 0.5)
    }
}

private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.body)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct MenuRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    /// The title stays outside the menu: a menu fades its whole label while it is open.
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.body)
            Spacer(minLength: 12)
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.value == selection }?.title ?? "")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct ModelRow: View {
    let title: String
    let subtitle: String
    let state: ModelManager.State
    /// Shown as a trash button once the model is on the device.
    var onDelete: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .notInstalled:
                Button("Download", action: action).buttonStyle(PillButtonStyle())
            case .installed, .ready:
                // Downloaded; the model is loaded into memory when it is first used.
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandSky)
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete")
                }
            case .downloading(let progress):
                ProgressView(value: progress)
                    .tint(Color.brandSky)
                    .frame(width: 80)
            case .loading:
                ProgressView()
            case .failed:
                Button("Retry", action: action).buttonStyle(PillButtonStyle(fill: Color(red: 1, green: 0.42, blue: 0.42)))
            }
        }
    }
}

/// Small capsule button: a wash of the color, like the main buttons.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = .brandSky

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brandNavy)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(fill.opacity(pressed ? 0.3 : 0.18), in: Capsule())
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}

private extension View {
    /// Text input with a hairline.
    func brandField() -> some View {
        self
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Look.hairline, lineWidth: Look.outline))
    }
}

#if os(macOS)
// MARK: - Dictation (Mac)

extension SettingsView {
    fileprivate var dictationCard: some View {
        let _ = permissionTick
        return SettingsCard(title: "Dictation") {
            Toggle("Dictate with a shortcut", isOn: $dictationEnabled)
                .font(.body)
                .tint(Color.brandSky)
                .onChange(of: dictationEnabled) { DictationController.shared.reloadShortcut() }
            CardDivider()
            HStack {
                Text("Shortcut").font(.body)
                Spacer(minLength: 12)
                ShortcutRecorderButton(
                    text: DictationSettings.description(modifiers: UInt32(shortcutModifiers), keyLabel: shortcutLabel)
                )
            }
            if DictationController.shared.shortcutUnavailable, dictationEnabled {
                Text("Another app already uses this shortcut. Choose a different one.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if DictationController.shared.shortcutNeedsAccessibility, dictationEnabled {
                Text("A modifier key on its own needs the Accessibility permission (below).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Click, then press a key combination or a single right-hand modifier key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MenuRow(
                title: "Mode",
                selection: $dictationMode,
                options: DictationMode.allCases.map { (value: $0, title: $0.label) }
            )
            Toggle("Play sounds", isOn: $dictationSounds)
                .font(.body)
                .tint(Color.brandSky)
            Toggle("Restore the clipboard after pasting", isOn: $keepClipboard)
                .font(.body)
                .tint(Color.brandSky)
            CardDivider()
            PermissionRow(
                title: "Microphone",
                granted: AVAudioApplication.shared.recordPermission == .granted
            ) {
                if AVAudioApplication.shared.recordPermission == .undetermined {
                    Task {
                        _ = await AVAudioApplication.requestRecordPermission()
                        permissionTick += 1
                    }
                } else {
                    PermissionRow.openPrivacy("Privacy_Microphone")
                }
            }
            PermissionRow(title: "Accessibility (to paste)", granted: TextInserter.canPaste) {
                TextInserter.requestAccess()
            }
            if !TextInserter.canPaste {
                Text("Switch Porridge on under Accessibility in System Settings. If it is already on there, switch it off and on again — macOS forgets the permission when the app was replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // The permissions are given outside the app: re-read them every second until they are there.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !TextInserter.canPaste || AVAudioApplication.shared.recordPermission != .granted else { return }
            permissionTick += 1
        }
        .onChange(of: permissionTick) {
            if DictationController.shared.shortcutNeedsAccessibility, TextInserter.canPaste {
                DictationController.shared.reloadShortcut()
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.body)
            Spacer(minLength: 12)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandSky)
            } else {
                Button("Allow", action: action).buttonStyle(PillButtonStyle())
            }
        }
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Click, then press the new shortcut: a key with modifiers, or one of the right-hand modifier keys
/// on its own. Escape cancels.
private struct ShortcutRecorderButton: View {
    let text: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut …" : text) {
            recording ? stop() : start()
        }
        .buttonStyle(PillButtonStyle(fill: recording ? .white : .brandSky))
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let keyCode = Int(event.keyCode)
            guard let label = DictationSettings.modifierKeyLabels[keyCode],
                  let mask = ModifierKeyMonitor.mask(for: keyCode),
                  CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(mask)
            else { return event }
            save(keyCode: keyCode, modifiers: 0, label: label)
            return nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let modifiers = DictationSettings.carbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // Plain typing keys would stop working everywhere: ask for a modifier (function keys may stand alone).
            guard modifiers != 0 || DictationSettings.isFunctionKey(Int(event.keyCode)) else {
                NSSound.beep()
                return nil
            }
            save(keyCode: Int(event.keyCode), modifiers: Int(modifiers), label: DictationSettings.label(for: event))
            return nil
        }
    }

    private func save(keyCode: Int, modifiers: Int, label: String) {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: DictationSettings.keyCodeKey)
        defaults.set(modifiers, forKey: DictationSettings.modifiersKey)
        defaults.set(label, forKey: DictationSettings.keyLabelKey)
        stop()
        DictationController.shared.reloadShortcut()
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
    }
}
#endif

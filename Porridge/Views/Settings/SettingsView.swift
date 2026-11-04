import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

struct SettingsView: View {
    @Environment(ModelManager.self) private var models
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.languageKey) private var language = "auto"
    @AppStorage(AppSettings.speechEngineKey) private var engine = SpeechEngine.parakeet
    @AppStorage(AppSettings.speakerDetectionKey) private var speakerDetection = true
    @AppStorage(AppSettings.recordsNewNotesKey) private var recordsNewNotes = false
    @AppStorage(AppSettings.voiceRecognitionKey) private var voiceRecognition = true
    @State private var showTemplates = false
    @AppStorage(AppSettings.myNameKey) private var myName = ""


    @State private var defaultModel = SummaryModel.current
    @State private var externalModels = SummaryModel.external
    @State private var showAddModel = false
    @State private var inputDescription = ""
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
    @State private var showPlaudLogin = false
    @State private var plaudSignedIn = PlaudAccount.isSignedIn

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

    /// A page of the list column (iOS), under its bar: no own stack or Done button.
    var isEmbedded = false
    /// Opens a note that was imported here; without it (Mac: a window of its own) the card says it is done.

    /// The Settings window of the Mac has no bar of its own above the content: give the first section air.
    private var settingsTopPadding: CGFloat {
        #if os(macOS)
        20
        #else
        4
        #endif
    }

    var body: some View {
        if isEmbedded {
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
        .toolbar(isEmbedded ? .hidden : .automatic, for: .navigationBar)
        #endif
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionTick += 1
        }
        #endif
        .onAppear {
            refreshInput()
            models.refreshLLM()
            refreshSummaryModels()
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
        .sheet(isPresented: $showTemplates) { SummaryTemplatesView() }
        .sheet(isPresented: $showAddModel, onDismiss: refreshSummaryModels) {
            AddModelSheet(onChange: refreshSummaryModels)
        }
        .sheet(isPresented: $showPlaudLogin) {
            PlaudLoginView { token, refreshToken in
                PlaudImporter().signIn(token: token, refreshToken: refreshToken)
                plaudChanged()
            }
        }
        .alert("Download Failed", isPresented: Binding(get: { modelError != nil }, set: { if !$0 { modelError = nil } })) {
            Button("OK") { modelError = nil }
        } message: {
            Text(modelError ?? "")
        }
        .onChange(of: models.llm) {
            reportFailure(in: Array(models.llm.values))
            refreshSummaryModels()
        }
        .onChange(of: models.asr) { reportFailure(in: [models.asr]) }
        .onChange(of: models.diarizer) { reportFailure(in: [models.diarizer]) }
        .onChange(of: language) { Task { await models.refreshASR() } }
        .onChange(of: engine) { Task { await models.refreshASR() } }
    }

    /// Order: what happens to a recording (transcription, speakers, summary), then imports, sync and about. Transcription always runs on the device.
    @ViewBuilder
    private var cards: some View {
        #if os(macOS)
        dictationCard
        #endif
        youCard
        transcriptionCard
        speakersCard
        summaryCard
        plaudCard
        SyncCard()
        aboutCard
    }


    // MARK: - Cards

    /// Who the user is: the summaries name them.
    private var youCard: some View {
        SettingsCard(title: "You") {
            TextField("Your Name", text: $myName)
                .textContentType(.name)
                .autocorrectionDisabled()
                .brandField()
                // The name follows the user to their other devices.
                .onChange(of: myName) { NextcloudSync.shared.syncSoon() }
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
                    state: models.asr, onDelete: { pendingDeletion = .speech },
                    onCancel: { Task { await models.deleteASR() } }
                ) {
                    Task { try? await models.ensureLocalASR() }
                }
            }
            CardDivider()
            MenuRow(
                title: "Language",
                selection: $language,
                options: AppSettings.languages.map { (value: $0.code, title: $0.name) }
            )
            CardDivider()
            ValueRow(title: "Microphone", value: inputDescription)
            CardDivider()
            Toggle("Record New Notes Automatically", isOn: $recordsNewNotes)
                .font(.body)
                .tint(Color.brandSky)
        }
    }

    /// Who said what: speaker detection with its model, then known voices.
    private var speakersCard: some View {
        SettingsCard(title: "Speakers") {
            ModelRow(
                title: "Speaker Model", subtitle: "pyannote · on this device · approx. 30 MB", state: models.diarizer,
                onDelete: { pendingDeletion = .speakers }
            ) {
                Task { try? await models.ensureDiarizer() }
            }
            CardDivider()
            Toggle("Detect Speakers", isOn: $speakerDetection)
                .font(.body)
                .tint(Color.brandSky)
            if speakerDetection {
                CardDivider()
                Toggle("Recognize Known Voices", isOn: $voiceRecognition)
                    .font(.body)
                    .tint(Color.brandSky)
                CardDivider()
                VoicesRow()
            }
        }
    }

    private var plaudCard: some View {
        SettingsCard(title: "Plaud") {
            HStack {
                Text(plaudSignedIn ? "Signed In" : "Plaud Account").font(.body)
                Spacer(minLength: 12)
                Button(plaudSignedIn ? "Sign Out" : "Sign In", role: plaudSignedIn ? .destructive : nil) {
                    if plaudSignedIn {
                        PlaudAccount.clear()
                        plaudChanged()
                    } else {
                        showPlaudLogin = true
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    private func plaudChanged() {
        plaudSignedIn = PlaudAccount.isSignedIn
        NotificationCenter.default.post(name: .plaudAccountChanged, object: nil)
    }

    private var summaryCard: some View {
        SettingsCard(title: "AI Summary") {
            HStack {
                Text("Custom Templates").font(.body)
                Spacer(minLength: 12)
                Button("Edit") { showTemplates = true }.buttonStyle(PillButtonStyle())
            }
            CardDivider()

            if SummaryModel.available.isEmpty {
                ValueRow(title: "Default Model", value: "None added")
            } else {
                MenuRow(
                    title: "Default Model",
                    selection: Binding(get: { defaultModel }, set: {
                        defaultModel = $0
                        SummaryModel.current = $0
                    }),
                    options: SummaryModel.available.map { (value: $0, title: $0.name) }
                )
            }
            CardDivider()

            if AppleLLM.availability == .available {
                ModelRow(
                    title: LocalModel.apple.displayName, subtitle: "On this device · built into the system",
                    state: .installed
                ) {}
            }
            ForEach(addedLocalModels) { model in
                ModelRow(
                    title: model.displayName,
                    subtitle: "On this device · " + model.sizeText,
                    state: models.llmState(model),
                    onDelete: { pendingDeletion = .summary(model) },
                    onCancel: { Task { await models.deleteLLM(model) } }
                ) {
                    Task { await models.downloadLLM(model) }
                }
            }
            ForEach(externalModels) { model in
                ModelRow(
                    title: model.name, subtitle: model.place, state: .installed,
                    onDelete: {
                        SummaryModel.remove(model)
                        refreshSummaryModels()
                    }
                ) {}
            }
            CardDivider()
            HStack {
                Text("Add Model").font(.body)
                Spacer(minLength: 12)
                Button("Add") { showAddModel = true }.buttonStyle(PillButtonStyle())
            }
        }
    }

    /// On the device or on the way there. The others are offered in `AddModelSheet`.
    private var addedLocalModels: [LocalModel] {
        LocalModel.downloadable.filter { model in
            switch models.llmState(model) {
            case .installed, .ready, .downloading, .loading: true
            default: false
            }
        }
    }

    /// The default must be something that can be chosen.
    private func refreshSummaryModels() {
        SummaryModel.repairCurrent()
        defaultModel = SummaryModel.current
        externalModels = SummaryModel.external
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
            if AppUpdate.isEnabled { updateRow }
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
            // The system only lists external inputs once the session is set up for recording. Only set up, not
            // activated: activating would stop the music or podcast of other apps just for showing this row.
            try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
        }
        let inputs = session.availableInputs ?? []
        let current = session.currentRoute.inputs.first
        let input = inputs.first { $0.portType != .builtInMic } ?? current ?? inputs.first
        if let input {
            let channels = isRecording && input.uid == current?.uid ? session.inputNumberOfChannels : (input.channels?.count ?? 1)
            inputDescription = channels > 1 ? "\(input.portName) · \(channels) channels" : input.portName
        } else {
            inputDescription = "Built-in Microphone"
        }
        #else
        inputDescription = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Microphone"
        #endif
    }
}

// MARK: - Building blocks

/// Settings group in the style of the list: a section head with a hairline, rows on the white page.
/// Where the notes go: iCloud between Apple devices, a Nextcloud for every platform, or nowhere. Switching
/// takes effect at the next launch.
private struct SyncCard: View {
    @AppStorage(SyncMode.key) private var mode: SyncMode = .iCloud
    @Environment(\.openURL) private var openURL
    @State private var sync = NextcloudSync.shared
    @AppStorage(AppSettings.recordingsWiFiOnlyKey) private var recordingsWiFiOnly = true
    @State private var server = ""
    @State private var login: Task<Void, Never>?
    @State private var loginError: String?

    var body: some View {
        SettingsCard(title: "Sync") {
            MenuRow(title: "Sync With", selection: $mode, options: SyncMode.allCases.map { (value: $0, title: $0.label) })
            if mode != SyncMode.active {
                Label("Restart Porridge to switch to \(mode.label).", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            switch mode {
            case .off:
                EmptyView()
            case .iCloud:
                let available = FileManager.default.ubiquityIdentityToken != nil
                Label(
                    available ? "Signed in to iCloud" : "Not signed in to iCloud",
                    systemImage: available ? "checkmark.icloud.fill" : "xmark.icloud"
                )
                .foregroundStyle(available ? Color.accentColor : Color.accentColor.opacity(0.6))
            case .nextcloud:
                if let account = sync.account {
                    ValueRow(title: "Account", value: account.label)
                    ValueRow(title: "Status", value: status)
                    Toggle("Upload Recordings on Wi-Fi Only", isOn: $recordingsWiFiOnly)
                        .font(.body)
                        .tint(Color.brandSky)
                        .onChange(of: recordingsWiFiOnly) { sync.wifiOnlyChanged() }
                    HStack(spacing: 10) {
                        Spacer()
                        Button(sync.isSyncing ? "Syncing…" : "Sync Now") { Task { await sync.sync() } }
                            .disabled(sync.isSyncing || SyncMode.active != .nextcloud)
                        Button("Disconnect", role: .destructive) { sync.disconnect() }
                    }
                    .buttonStyle(PillButtonStyle())
                } else {
                    TextField("Server, e.g. cloud.example.com", text: $server)
                        .urlFieldStyle()
                        .brandField()
                    HStack(spacing: 10) {
                        Spacer()
                        if login == nil {
                            Button("Connect") { connect() }
                                .disabled(NextcloudLogin.normalize(server) == nil)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Confirm the login in your browser.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Cancel") { login?.cancel(); login = nil }
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    if let loginError {
                        Text(loginError).font(.subheadline).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var status: String {
        if sync.isSyncing { return "Syncing…" }
        if SyncMode.active != .nextcloud { return "After restart" }
        if let error = sync.lastError { return error }
        guard let last = sync.lastSync else { return "Not synced yet" }
        return "Synced \(last.formatted(.relative(presentation: .named)))"
    }

    private func connect() {
        guard let url = NextcloudLogin.normalize(server) else { return }
        loginError = nil
        login = Task {
            defer { login = nil }
            do {
                let pending = try await NextcloudLogin.start(server: url)
                openURL(pending.loginURL)
                let account = try await NextcloudLogin.finish(pending)
                sync.connect(account)
            } catch is CancellationError {
            } catch {
                loginError = error.localizedDescription
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
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

struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Look.hairline)
            .frame(height: 0.5)
    }
}

struct ValueRow: View {
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

struct MenuRow<Value: Hashable>: View {
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

struct ModelRow: View {
    let title: String
    let subtitle: String
    let state: ModelManager.State
    /// Shown as a trash button once the model is on the device.
    var onDelete: (() -> Void)?
    /// A long press on the row stops the download while it runs, after asking.
    var onCancel: (() -> Void)?
    let action: () -> Void

    @State private var confirmCancel = false

    private var canCancel: Bool {
        if case .downloading = state { onCancel != nil } else { false }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(canCancel ? "Press and hold to cancel" : subtitle)
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
                Button("Retry", action: action).buttonStyle(PillButtonStyle(fill: Color.brandAlert))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in confirmCancel = true },
            including: canCancel ? .all : .subviews
        )
        .accessibilityAction(named: "Cancel Download") { if canCancel { confirmCancel = true } }
        .alert("Cancel download of \(title)?", isPresented: $confirmCancel) {
            Button("Keep Downloading", role: .cancel) {}
            Button("Cancel Download", role: .destructive) {
                // It may have finished while the question was open: then there is nothing to stop, and the model stays.
                if canCancel { onCancel?() }
            }
        } message: {
            Text("What has been downloaded so far will be deleted.")
        }
    }
}

/// Small capsule button: a wash of the color, like the main buttons.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = .brandSky
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(destructive ? Color.red : Color.brandNavy)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background((destructive ? Color.red : fill).opacity(pressed ? 0.3 : 0.18), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}

extension View {
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
        Button(recording ? "Press shortcut…" : text) {
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

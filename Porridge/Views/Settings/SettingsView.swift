import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The areas the settings are split into; one shows at a time, chosen with the pills on top.
enum SettingsArea: String, CaseIterable {
    case general, recording, ai, sync, about

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .ai: "AI"
        case .sync: "Sync"
        case .about: "About"
        }
    }
}

struct SettingsView: View {
    @Environment(ModelManager.self) private var models
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.languageKey) private var language = "auto"
    @AppStorage(AppSettings.speechEngineKey) private var engine = SpeechEngine.parakeet
    @AppStorage(AppSettings.speakerDetectionKey) private var speakerDetection = true
    @AppStorage(AppSettings.recordsNewNotesKey) private var recordsNewNotes = false
    @AppStorage(AppSettings.summarizeIncomingKey) private var summarizeIncoming = true
    @AppStorage(AppSettings.voiceRecognitionKey) private var voiceRecognition = true
    @State private var showTemplates = false
    /// The area of the settings that shows; kept while the app runs, so coming back from a subpage finds it again.
    @SceneStorage("settingsArea") private var area = SettingsArea.general
    @AppStorage(AppSettings.myNameKey) private var myName = ""

    @State private var defaultModel = SummaryModel.current
    @State private var externalModels = SummaryModel.external
    @State private var showAddModel = false
    @State private var inputDescription = ""
    @State private var pendingDeletion: ModelKind?
    @State private var modelError: String?
    @State private var showPlaudLogin = false
    @State private var modelToRemove: SummaryModel?
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

    /// Air above the first section, under the bar.
    private var settingsTopPadding: CGFloat {
        4
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
            // The areas of the settings as pills, like the kinds in a bucket: one area shows at a time.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SettingsArea.allCases, id: \.self) { areaPill($0) }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, settingsTopPadding)
            .padding(.bottom, Look.headerGap)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 32) { cards }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color.appBackground)
        .brandNavigationTitle("Settings")
        // Pushed: our own bar (ChromeBar) replaces the system one.
        .toolbar(isEmbedded ? .hidden : .automatic, for: .navigationBar)
        .onAppear {
            refreshInput()
            models.refreshLLM()
            refreshSummaryModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { refreshInput() }
        }
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
        .onChange(of: models.spareParakeet) { reportFailure(in: [models.spareParakeet]) }
        .onChange(of: models.diarizer) { reportFailure(in: [models.diarizer]) }
        .onChange(of: language) { Task { await models.refreshASR() } }
        .onChange(of: engine) { Task { await models.refreshASR() } }
    }

    /// The cards of the chosen area. Transcription always runs on the device.
    @ViewBuilder
    private var cards: some View {
        switch area {
        case .general:
            youCard
            plaudCard
        case .recording:
            transcriptionCard
            speakersCard
        case .ai:
            summaryCard
        case .sync:
            SyncCard()
        case .about:
            aboutCard
        }
    }

    private func areaPill(_ option: SettingsArea) -> some View {
        let isOn = area == option
        return Button { withAnimation(.snappy) { area = option } } label: {
            Text(option.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.brandOnNavy : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? Color.brandNavy : Color.brandNavy.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
            // Built like the AI card: the default on top, then the models on this device.
            if SpeechEngine.available.count > 1 {
                MenuRow(
                    title: "Default Model",
                    selection: $engine,
                    options: SpeechEngine.available.map { (value: $0, title: $0.shortLabel) }
                )
            } else {
                ValueRow(title: "Default Model", value: engine.shortLabel)
            }
            CardDivider()

            if SpeechEngine.available.contains(.apple) {
                // Not the default: the system has it, its language pack loads once it is chosen.
                ModelRow(
                    title: "Apple Speech", subtitle: "On this device · built into the system",
                    state: engine == .apple ? models.asr : .installed
                ) {
                    Task { try? await models.ensureLocalASR() }
                }
            }
            ModelRow(
                title: "Parakeet TDT v3", subtitle: "On this device · 25 languages · approx. 480 MB",
                state: engine == .parakeet ? models.asr : models.spareParakeet,
                onDelete: { pendingDeletion = .speech },
                onCancel: { Task { await models.deleteASR() } }
            ) {
                Task {
                    if engine == .parakeet { try? await models.ensureLocalASR() } else { await models.downloadSpareParakeet() }
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
                        Task { await PlaudLoginView.clearSession() }
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

            // Links, images, files, shared text and imported audio are summarized as they come in (`AutoSummary`).
            Toggle("Summarize Incoming Entries", isOn: $summarizeIncoming)
            CardDivider()

            HStack {
                Text("Custom Templates").font(.body)
                Spacer(minLength: 12)
                Button("Edit") { showTemplates = true }.buttonStyle(PillButtonStyle())
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
                    onDelete: { modelToRemove = model }
                ) {}
                .confirmationDialog(
                    "Remove \(model.name)?",
                    isPresented: .init(get: { modelToRemove?.id == model.id }, set: { if !$0 { modelToRemove = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        SummaryModel.remove(model)
                        refreshSummaryModels()
                    }
                } message: {
                    Text("You can add it again at any time.")
                }
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
            CardDivider()
            AcknowledgementsRow()
        }
    }

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
    }
}

// MARK: - Building blocks

/// Settings group in the style of the list: a section head with a hairline, rows on the white page.
/// Where the notes go: iCloud between Apple devices, a Nextcloud for every platform, or nowhere. Switching
/// takes effect at the next launch.
private struct SyncCard: View {
    @State private var confirmDisconnect = false
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
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                            .confirmationDialog("Disconnect from Nextcloud?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                                Button("Disconnect", role: .destructive) { sync.disconnect() }
                            } message: {
                                Text("Your notes stay on this device and on the server. They are no longer kept in sync.")
                            }
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
                        Text(loginError).font(.subheadline).foregroundStyle(Color.brandDangerText)
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
                        .foregroundStyle(Color.brandDangerText)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .notInstalled:
                Button("Download", action: action).buttonStyle(PillButtonStyle())
            case .installed, .ready, .loading:
                // On the device. Whether it is in memory yet (loading, ready) is nothing to show here; it is not
                // deleted while it loads.
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandSkyText)
                if let onDelete, state != .loading {
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(Color.brandDangerText)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete")
                }
            case .downloading(let progress):
                ProgressView(value: progress)
                    .tint(Color.brandSky)
                    .frame(width: 80)
            case .failed:
                Button("Retry", action: action).buttonStyle(PillButtonStyle(fill: Color.red))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in confirmCancel = true },
            including: canCancel ? .all : .subviews
        )
        .accessibilityAction(named: "Cancel Download") { if canCancel { confirmCancel = true } }
        .alert("Cancel Download of \(title)?", isPresented: $confirmCancel) {
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
            .foregroundStyle(destructive ? Color.brandDangerText : Color.brandNavy)
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


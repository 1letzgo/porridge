import SwiftUI

/// Lists the recordings on a Plaud recorder and copies the chosen ones into Porridge as meetings.
struct PlaudImportSheet: View {
    var onImport: (PlaudImportedAudio) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var importer = PlaudImporter()
    @State private var showLogin = false

    private var newRecordings: [PlaudRecording] { importer.recordings.filter { !$0.imported } }

    var body: some View {
        NavigationStack {
            Group {
                if !importer.signedIn {
                    signedOut
                } else if importer.recordings.isEmpty {
                    waiting
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appGroupedBackground)
            .brandNavigationTitle("Plaud")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(importer.importingId != nil)
                }
                if importer.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { Task { await importer.refresh() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) { importer.signOut() } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .disabled(importer.importingId != nil)
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                PlaudLoginView { token, refreshToken in
                    importer.signIn(token: token, refreshToken: refreshToken)
                    Task { await importer.refresh() }
                }
            }
            .alert("Plaud", isPresented: .constant(importer.errorMessage != nil)) {
                Button("OK") { importer.errorMessage = nil }
            } message: {
                Text(importer.errorMessage ?? "")
            }
            .task {
                if importer.signedIn { await importer.refresh() }
            }
            .onDisappear { importer.disconnect() }
        }
        .interactiveDismissDisabled(importer.importingId != nil)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
        #endif
    }

    private var signedOut: some View {
        VStack(spacing: 20) {
            EmptyStateView(title: "Plaud Recorder", message: "Sign in to Plaud once. After that the recordings come straight from the recorder over Bluetooth.", systemImage: "waveform")
            Button("Sign In to Plaud") { showLogin = true }
                .buttonStyle(ChunkyButtonStyle())
                .padding(.horizontal, 40)
        }
    }

    private var waiting: some View {
        VStack(spacing: 20) {
            if importer.isWorking {
                ProgressView().controlSize(.large)
                Text(importer.status.isEmpty ? "Connecting …" : importer.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Wake the recorder with its button. Close the Plaud app if it is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                EmptyStateView(
                    title: importer.status.isEmpty ? "No Recorder Found" : "Nothing to Import",
                    message: importer.status.isEmpty ? "Wake the recorder with its button and try again." : importer.status,
                    systemImage: "waveform"
                )
                Button("Try Again") { Task { await importer.refresh() } }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 40)
            }
        }
        .padding()
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(importer.recordings) { recording in
                        row(recording)
                    }
                }
                .padding()
            }
            if !newRecordings.isEmpty {
                Button {
                    Task { await importAll() }
                } label: {
                    Text(newRecordings.count == 1 ? "Import 1 Recording" : "Import \(newRecordings.count) Recordings")
                }
                .buttonStyle(ChunkyButtonStyle())
                .disabled(importer.importingId != nil)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    private func row(_ recording: PlaudRecording) -> some View {
        let isImporting = importer.importingId == recording.sessionId
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.headline)
                    .foregroundStyle(Color.brandNavy)
                Text(ByteCountFormatter.string(fromByteCount: Int64(recording.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(Color.brandNavy.opacity(0.6))
                if isImporting {
                    ProgressView(value: importer.progress)
                        .tint(Color.brandSky)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if isImporting {
                Button("Stop") { importer.cancelImport() }
                    .buttonStyle(PillButtonStyle())
            } else if recording.imported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.brandSky)
                    .accessibilityLabel("Imported")
            } else {
                Button("Import") { Task { await importOne(recording) } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(importer.importingId != nil)
            }
        }
        .chunkyCard()
    }

    private func importOne(_ recording: PlaudRecording) async {
        if let audio = await importer.importRecording(recording) { onImport(audio) }
    }

    private func importAll() async {
        for recording in newRecordings {
            guard let audio = await importer.importRecording(recording) else { return }
            onImport(audio)
        }
    }
}

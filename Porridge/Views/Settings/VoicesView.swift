import SwiftData
import SwiftUI

/// The row in the settings that leads to the known voices.
struct VoicesRow: View {
    @Query private var voices: [VoiceProfile]
    #if os(macOS)
    @State private var isShown = false
    #endif

    @Environment(\.openListPage) private var openListPage

    var body: some View {
        #if os(iOS)
        Button { openListPage(.voices) } label: { label }
            .buttonStyle(.plain)
        #else
        Button { isShown = true } label: { label }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShown) {
                VoicesView()
                    .frame(width: 520, height: 560)
            }
        #endif
    }

    private var label: some View {
        HStack {
            Text("Known Voices").font(.body)
            Spacer(minLength: 12)
            Text("\(voices.count)").font(.body).foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The voices Porridge has learned: which one is yours, what they are called, and forgetting one.
struct VoicesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceProfile.name) private var voices: [VoiceProfile]
    @AppStorage(AppSettings.myVoiceKey) private var myVoice = ""
    @State private var renaming: VoiceProfile?
    @State private var newName = ""
    @State private var forgetting: VoiceProfile?

    /// The user's own voice on top.
    private var sorted: [VoiceProfile] {
        voices.sorted { ($0.id.uuidString == myVoice ? 0 : 1) < ($1.id.uuidString == myVoice ? 0 : 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            HStack {
                Text("Known Voices").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sorted) { voice in
                        row(voice)
                        Rectangle().fill(Look.hairline).frame(height: 0.5)
                    }
                    // Without voices the page would otherwise be empty, with nothing to say how one gets there.
                    if voices.isEmpty {
                        Text("No voices yet. Naming a speaker in a meeting teaches Porridge the voice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
        }
        .background(Color.appBackground)
        .brandNavigationTitle("Known Voices")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .alert("Rename Voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let renaming, !name.isEmpty {
                    VoiceProfiles.rename(renaming, to: name, context: context)
                }
                renaming = nil
            }
        }
        .alert("Forget this voice?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Cancel", role: .cancel) { forgetting = nil }
            Button("Forget Voice", role: .destructive) {
                if let forgetting { VoiceProfiles.delete(forgetting, context: context) }
                forgetting = nil
            }
        } message: {
            Text("Names already given in meetings stay.")
        }
    }

    private func row(_ voice: VoiceProfile) -> some View {
        let isMe = voice.id.uuidString == myVoice
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(voice.name) (me)" : voice.name).font(.body)
                Text("\(voice.seconds.clockString) of speech")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy) { AppSettings.setMyVoice(isMe ? nil : voice) }
            } label: {
                Image(systemName: isMe ? "person.crop.circle.fill" : "person.crop.circle")
                    .foregroundStyle(isMe ? Color.brandTask : Color.accentColor)
            }
            .accessibilityLabel(isMe ? "Not Me" : "This Is Me")
            Button {
                newName = voice.name
                renaming = voice
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Rename")
            Button {
                forgetting = voice
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .accessibilityLabel("Forget Voice")
        }
        .buttonStyle(.borderless)
    }
}

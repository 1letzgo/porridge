import SwiftData
import SwiftUI

/// Pick the meetings to add to `base`; they are combined into it in time order.
struct MergeNotesSheet: View {
    let base: Note
    var onMerged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Query(sort: \Note.createdAt, order: .reverse) private var meetings: [Note]

    @State private var selection = Set<UUID>()
    @State private var isMerging = false
    @State private var errorMessage: String?

    private var candidates: [Note] {
        meetings.filter { $0.id != base.id && !$0.isDeleted && $0.isRecording && $0.status == .ready && processing.stages[$0.id] == nil }
    }

    private var chosen: [Note] {
        candidates.filter { selection.contains($0.id) }
    }

    /// Without every recording on this device the audio cannot be joined and is dropped.
    private var losesAudio: Bool {
        !chosen.isEmpty && !([base] + chosen).allSatisfy(\.hasLocalAudio)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    EmptyStateView(title: "Nothing to Merge", message: "There are no other finished recordings.", systemImage: "person.2.wave.2")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(candidates) { meeting in
                                row(meeting)
                            }
                        }
                        .padding()
                    }
                }
                footer
            }
            .background(Color.appGroupedBackground)
            .brandNavigationTitle("Merge Recordings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isMerging)
                }
            }
            .alert("Merge Failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isMerging)
    }

    private func row(_ meeting: Note) -> some View {
        let selected = selection.contains(meeting.id)
        return Button {
            if selected { selection.remove(meeting.id) } else { selection.insert(meeting.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.brandSky : Color.brandNavy.opacity(0.35))
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Color.brandNavy)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(meeting.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        Text("·")
                        Text(meeting.duration.durationText)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.brandNavy.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .chunkyCard(fill: selected ? Color.brandSky.opacity(0.18) : nil)
        }
        .buttonStyle(.plain)
        .disabled(isMerging)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if losesAudio {
                Label("Some recordings are not on this device. The merged meeting will have no audio.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.brandNavy.opacity(0.7))
            } else if !chosen.isEmpty {
                Text("Combined in time order into “\(base.title)”. The other meetings are removed.")
                    .font(.footnote)
                    .foregroundStyle(Color.brandNavy.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await merge() }
            } label: {
                if isMerging {
                    ProgressView().tint(Color.brandNavy)
                } else {
                    Text(chosen.isEmpty ? "Merge" : "Merge \(chosen.count + 1) Recordings")
                }
            }
            .buttonStyle(ChunkyButtonStyle())
            .disabled(chosen.isEmpty || isMerging)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private func merge() async {
        isMerging = true
        defer { isMerging = false }
        do {
            try await NoteMerger.merge(chosen, into: base, context: context)
            onMerged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

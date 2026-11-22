import SwiftUI

/// Rewrites the selection of a note with AI: an instruction (typed, a quick preset or a saved one), the model, then
/// a preview of the changes with Replace, Insert Below and Try Again. The same view on iOS (a sheet) and the Mac
/// (a sheet of the window).
struct AIRewriteView: View {
    let request: RewriteRequest
    /// Puts the text into the note (`insertBelow`: on new lines after the selection). False when the selection
    /// is not in the note anymore.
    let apply: (_ text: String, _ insertBelow: Bool) -> Bool
    let close: () -> Void

    private enum Phase: Equatable {
        case compose
        case running(String)
        case result(String)
        case failed(String)
    }

    @State private var phase = Phase.compose
    @State private var instruction = ""
    /// The instruction the last result was written for (Try Again asks with it again).
    @State private var asked = ""
    @State private var model = SummaryModel.current
    @State private var custom = RewritePresetStore.shared.presets
    @State private var removed: (preset: RewritePreset, index: Int)?
    @State private var showsChanges = true
    @State private var applyFailed = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private static let navy = Color("BrandNavy")
    private static let sky = Color("BrandSkyText")
    private static let green = Color("BrandTask")
    private static let danger = Color("BrandDangerText")
    private static let hairline = Color.primary.opacity(0.1)

    private var selection: String { request.target.selected }

    private var models: [SummaryModel] {
        var models = SummaryModel.available
        if !models.contains(SummaryModel.current) { models.insert(SummaryModel.current, at: 0) }
        return models
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Rewrite with AI").font(.headline)
                Spacer()
                // Balances Cancel so the title stays in the middle.
                Button("Cancel") {}.hidden().accessibilityHidden(true)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .compose: compose
                    case .running(let status): running(status)
                    case .result(let text): result(text)
                    case .failed(let message): failed(message)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(macOS)
        .frame(width: 520)
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 720)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .onDisappear { task?.cancel() }
    }

    // MARK: Compose

    @ViewBuilder
    private var compose: some View {
        excerpt(selection, lines: 4)
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Describe the change…", text: $instruction, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { run(instruction) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                .accessibilityIdentifier("rewrite.instruction")
            Button { run(instruction) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Self.navy)
            .disabled(trimmed(instruction).isEmpty)
            .opacity(trimmed(instruction).isEmpty ? 0.35 : 1)
            .accessibilityLabel("Rewrite")
        }
        if !trimmed(instruction).isEmpty, !custom.contains(where: { $0.instruction.caseInsensitiveCompare(trimmed(instruction)) == .orderedSame }) {
            Button {
                if RewritePresetStore.shared.save(instruction) != nil { custom = RewritePresetStore.shared.presets }
            } label: {
                Label("Save as Preset", systemImage: "bookmark")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Self.sky)
        }
        modelRow
        if !custom.isEmpty {
            presetSection("Your Presets", custom, removable: true)
        }
        if let removed {
            HStack {
                Text("“\(removed.preset.title)” removed").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    RewritePresetStore.shared.restore(removed.preset, at: removed.index)
                    custom = RewritePresetStore.shared.presets
                    self.removed = nil
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Self.sky)
            }
        }
        presetSection("Quick Actions", RewritePreset.builtIn, removable: false)
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(models) { option in
                    Button {
                        model = option
                    } label: {
                        if option == model { Label(option.menuTitle, systemImage: "checkmark") } else { Text(option.menuTitle) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(model.menuTitle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Model: \(model.menuTitle)")
            if let hint = model.sendsHint("selected text") {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            } else if !model.isUsable {
                Text(AIRewriteError.noModel.localizedDescription).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func presetSection(_ title: String, _ presets: [RewritePreset], removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Self.sky)
                .padding(.bottom, 6)
            Rectangle().fill(Self.hairline).frame(height: 0.5)
            ForEach(presets) { preset in
                Button { run(preset.instruction) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(Self.sky)
                        Text(preset.title)
                            .foregroundStyle(Self.navy)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.instruction)
                .contextMenu {
                    if removable {
                        Button(role: .destructive) { remove(preset) } label: { Label("Delete Preset", systemImage: "trash") }
                    }
                }
                Rectangle().fill(Self.hairline).frame(height: 0.5)
            }
        }
    }

    // MARK: Running, result, failure

    @ViewBuilder
    private func running(_ status: String) -> some View {
        excerpt(selection, lines: 4)
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(status).foregroundStyle(.secondary)
        }
        Text(asked).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
    }

    @ViewBuilder
    private func result(_ text: String) -> some View {
        HStack(spacing: 6) {
            toggle("Changes", on: showsChanges) { showsChanges = true }
            toggle("Result", on: !showsChanges) { showsChanges = false }
            Spacer()
            Text(model.name).font(.caption).foregroundStyle(.secondary)
        }
        Group {
            if showsChanges, let pieces = RewriteDiff.pieces(from: selection, to: text) {
                Text(Self.attributed(pieces))
            } else if showsChanges {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Before").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(selection).foregroundStyle(.secondary)
                    Text("After").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(text)
                }
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        let removedLinks = RewriteLinks.removedCount(original: selection, rewritten: text)
        if removedLinks > 0 {
            Text(removedLinks == 1 ? "1 link to an entry was removed." : "\(removedLinks) links to entries were removed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if applyFailed {
            Text("The selected text changed in the meantime, so the note was left as it is.")
                .font(.footnote)
                .foregroundStyle(Self.danger)
        }
        HStack(spacing: 10) {
            Button { finish(text, insertBelow: false) } label: { Label("Replace", systemImage: "checkmark") }
                .buttonStyle(WashButtonStyle(color: Self.navy, emphasized: true))
                .keyboardShortcut(.defaultAction)
            Button { finish(text, insertBelow: true) } label: { Label("Insert Below", systemImage: "text.insert") }
                .buttonStyle(WashButtonStyle(color: Self.navy))
        }
        HStack(spacing: 10) {
            Button { run(asked) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                .buttonStyle(WashButtonStyle(color: Self.sky))
            Button { back() } label: { Label("Change Instruction", systemImage: "pencil") }
                .buttonStyle(WashButtonStyle(color: Self.sky))
        }
        Text("Undo takes the change back.").font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func failed(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(Self.danger)
        HStack(spacing: 10) {
            Button { run(asked) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                .buttonStyle(WashButtonStyle(color: Self.navy, emphasized: true))
            Button { back() } label: { Label("Change Instruction", systemImage: "pencil") }
                .buttonStyle(WashButtonStyle(color: Self.sky))
        }
    }

    private func toggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? Self.navy.opacity(0.12) : .clear))
                .foregroundStyle(on ? Self.navy : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func excerpt(_ text: String, lines: Int) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Self.sky.opacity(0.6)).frame(width: 3)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Selected text: \(text)")
    }

    /// Removed words struck through on a red wash, added ones on a green wash.
    static func attributed(_ pieces: [RewriteDiff.Piece]) -> AttributedString {
        var result = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .same: break
            case .removed:
                part.strikethroughStyle = .single
                part.foregroundColor = .secondary
                part.backgroundColor = danger.opacity(0.14)
            case .added:
                part.backgroundColor = green.opacity(0.22)
            }
            result += part
        }
        return result
    }

    // MARK: Actions

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func run(_ text: String) {
        let instruction = trimmed(text)
        guard !instruction.isEmpty else { return }
        asked = instruction
        applyFailed = false
        task?.cancel()
        phase = .running("Writing…")
        let model = model
        let target = request.target
        task = Task { @MainActor in
            do {
                let answer = try await AIRewrite.run(instruction: instruction, target: target, model: model) { status in
                    if case .running = phase { phase = .running(status) }
                }
                guard !Task.isCancelled else { return }
                phase = .result(answer)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .failed(ChatService.message(for: error, model: model))
            }
        }
    }

    private func back() {
        task?.cancel()
        if instruction.isEmpty, !RewritePreset.builtIn.contains(where: { $0.instruction == asked }) { instruction = asked }
        phase = .compose
        fieldFocused = true
    }

    private func remove(_ preset: RewritePreset) {
        guard let index = RewritePresetStore.shared.remove(preset) else { return }
        custom = RewritePresetStore.shared.presets
        removed = (preset, index)
    }

    private func finish(_ text: String, insertBelow: Bool) {
        if apply(text, insertBelow) { close() } else { applyFailed = true }
    }

    private func cancel() {
        task?.cancel()
        close()
    }
}

/// A button on a soft wash of its color with the color as text, like the row icons; `emphasized` a little stronger.
private struct WashButtonStyle: ButtonStyle {
    let color: Color
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(emphasized ? 0.18 : 0.1)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

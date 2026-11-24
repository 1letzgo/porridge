import SwiftData
import SwiftUI

/// The changes an answer proposes, one card each: Confirm or Cancel, and "Confirm All" when there are several.
/// Nothing changes before a tap; after it the card says what happened.
struct ChatActionCards: View {
    let entryID: UUID

    @Environment(\.modelContext) private var context
    private var service: ChatService { ChatService.shared }

    var body: some View {
        let actions = service.actions(for: entryID)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions) { action in
                    card(action)
                }
                let pending = actions.filter { $0.status == .pending }
                if pending.count > 1 {
                    HStack(spacing: 10) {
                        Button("Cancel All") { withAnimation(.snappy) { service.cancel(in: entryID) } }
                            .buttonStyle(.bordered)
                        Button("Confirm All (\(pending.count))") { withAnimation(.snappy) { service.confirm(in: entryID, context: context) } }
                            .buttonStyle(.borderedProminent)
                            .tint(.brandNavy)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func card(_ action: ChatAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.brandNavy)
                    .frame(width: 30, height: 30)
                    .background(Color.brandSky.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subject = action.subject {
                        Text("«\(subject)»")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            switch action.status {
            case .pending:
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Cancel") { withAnimation(.snappy) { service.cancel([action.id], in: entryID) } }
                        .buttonStyle(.bordered)
                    Button("Confirm") { withAnimation(.snappy) { service.confirm([action.id], in: entryID, context: context) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandNavy)
                }
                .font(.subheadline.weight(.semibold))
            default:
                Label(Self.statusText(action), systemImage: Self.statusSymbol(action.status))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(action.status == .failed ? Color.brandDangerText : action.status == .done ? Color.brandTaskText : .secondary)
            }
        }
        .padding(12)
        .brandSurface(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(action.title + (action.subject.map { ", " + $0 } ?? ""))
    }

    static func statusText(_ action: ChatAction) -> String {
        switch action.status {
        case .pending: "Waiting for confirmation"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .undone: "Undone"
        case .failed: "Could not be done" + (action.failure.map { ": " + $0 } ?? "")
        }
    }

    static func statusSymbol(_ status: ChatAction.Status) -> String {
        switch status {
        case .pending: "clock"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .undone: "arrow.uturn.backward.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

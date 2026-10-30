import SwiftUI

/// What the Summary tab shows while a summary is being written (same for meetings and notes).
struct SummarizingCard: View {
    let message: String
    let status: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.brandSky)
                .symbolEffect(.pulse)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {} label: {
                ProgressView().tint(Color.brandNavy)
            }
            .buttonStyle(ChunkyButtonStyle())
            .disabled(true)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

import SwiftUI

/// The one-time "What's New" card at the top of Today (`WhatsNew`): the three places, Details, Search or Ask and the
/// Chat tab, Triage, the Inbox swipes, the selection bar, Today showing what is open. "Got It" or × puts it away for
/// good (on this device).
struct WhatsNewCard: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(WhatsNew.title, systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.brandNavy)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .accessibilityLabel("Close What’s New")
            }
            ForEach(WhatsNew.items(mac: false), id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandSkyText)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.text).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button("Got It", action: onDismiss)
                .buttonStyle(ChunkyButtonStyle())
                .accessibilityIdentifier("WhatsNewDone")
        }
        .padding(14)
        .background(Color.brandSky.opacity(0.1), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WhatsNew")
    }
}

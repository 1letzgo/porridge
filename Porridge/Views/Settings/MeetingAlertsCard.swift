import SwiftUI

/// Settings › Recording: the notification shortly before a meeting, with Record, and which calendars count.
struct MeetingAlertsCard: View {
    @AppStorage(MeetingAlerts.enabledKey) private var enabled = false
    @State private var calendars: [(id: String, title: String, account: String)] = []
    @State private var excluded = MeetingAlerts.excludedCalendars
    @State private var access = CalendarAccess.status

    var body: some View {
        SettingsCard(title: "Meeting Alerts") {
            Toggle("Alert Before Meetings", isOn: Binding(get: { enabled }, set: { switchTo($0) }))
                .font(.body)
                .tint(Color.brandSky)
            Text("A notification a minute before an appointment with other people or a video call, with Record. Porridge only reads your calendars.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if enabled {
                switch access {
                case .granted:
                    ForEach(calendars, id: \.id) { calendar in
                        CardDivider()
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(calendar.id) },
                            set: { on in
                                if on { excluded.remove(calendar.id) } else { excluded.insert(calendar.id) }
                                MeetingAlerts.excludedCalendars = excluded
                                MeetingAlertScheduler.shared.refresh()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(calendar.title).font(.body)
                                if !calendar.account.isEmpty {
                                    Text(calendar.account).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(Color.brandSky)
                    }
                case .denied:
                    CardDivider()
                    Text("Calendar access is off. Allow it in the Settings app to get meeting alerts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PillButtonStyle())
                case .notDetermined:
                    EmptyView()
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func switchTo(_ on: Bool) {
        enabled = on
        guard on else {
            MeetingAlertScheduler.shared.disable()
            return
        }
        Task {
            await MeetingAlertScheduler.shared.enable()
            reload()
        }
    }

    private func reload() {
        access = CalendarAccess.status
        calendars = CalendarAccess.eventCalendars()
        excluded = MeetingAlerts.excludedCalendars
    }
}

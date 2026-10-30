import SwiftUI

/// Today's appointments; picking one starts a recording named after it. the "New Meeting" card on top starts one without.
struct RecordMeetingSheet: View {
    var onPick: (CalendarAppointment) -> Void
    var onNew: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = CalendarAccess.status
    @State private var appointments: [CalendarAppointment] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    newMeetingCard
                    switch status {
                    case .granted:
                        if appointments.isEmpty {
                            Text("No appointments in your calendars today.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        } else {
                            ForEach(appointments) { appointment in
                                row(appointment)
                            }
                        }
                    case .denied:
                        VStack(spacing: 12) {
                            Text("Calendar access is off. Allow Porridge to read your calendars to see today's appointments here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open Settings", action: openSettings)
                                .buttonStyle(PillButtonStyle())
                        }
                        .padding(.top, 8)
                    case .notDetermined:
                        ProgressView().padding(.top, 24)
                    }
                }
                .padding()
            }
            .background(Color.appGroupedBackground)
            .brandNavigationTitle("Record Meeting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    /// For meetings that are not in the calendar; on top of the list, in light blue.
    private var newMeetingCard: some View {
        Button {
            dismiss()
            onNew()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandNavy)
                Text("New Meeting")
                    .font(.headline)
                    .foregroundStyle(Color.brandNavy)
                Spacer(minLength: 8)
            }
            .chunkyCard(fill: Color.brandSky.opacity(0.35))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Meeting")
    }

    private func load() async {
        if status == .notDetermined {
            _ = await CalendarAccess.requestAccess()
            status = CalendarAccess.status
        }
        if status == .granted {
            appointments = CalendarAccess.todaysAppointments()
        }
    }

    private func row(_ appointment: CalendarAppointment) -> some View {
        Button {
            dismiss()
            onPick(appointment)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appointment.title)
                        .font(.headline)
                        .foregroundStyle(Color.brandNavy)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if appointment.isAllDay {
                            Text("All day")
                        } else {
                            Text(appointment.start, format: .dateTime.hour().minute())
                            Text("–")
                            Text(appointment.end, format: .dateTime.hour().minute())
                        }
                        Text("·")
                        Text(appointment.calendarName).lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandNavy.opacity(0.6))
                }
                Spacer(minLength: 8)
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandSky)
            }
            .chunkyCard()
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

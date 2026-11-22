import CloudKit
import SwiftUI
import UIKit

/// Sharing a bowl on iOS: the system's sheet for the people of a share (`UICloudSharingController`), and the
/// questions before stopping or leaving. Presented by UIKit over whatever is on screen, so every place that offers
/// sharing (a bowl's row, its page) uses the same few calls.
@MainActor
final class BowlShareController: NSObject, UICloudSharingControllerDelegate {
    static let shared = BowlShareController()

    private var shown: (bowlID: UUID, title: String)?

    /// Shares the bowl (made on the first time) and opens the sheet to invite people.
    func share(_ bowl: NoteFolder) {
        let bowlID = bowl.id
        let title = bowl.name
        Task {
            do {
                let share = try await BowlSharing.shared.share(bowl)
                present(share, bowlID: bowlID, title: title)
            } catch {
                BowlSharing.shared.notice = String(localized: "The bowl could not be shared. \(error.localizedDescription)")
            }
        }
    }

    /// The sheet of a shared bowl: who is in it, invite more, stop sharing (the owner) or leave (everyone else).
    func manage(_ bowl: NoteFolder) {
        guard let info = BowlSharing.shared.info(for: bowl.id) else { return share(bowl) }
        let title = bowl.name
        Task {
            do {
                let share = try await BowlSharing.shared.fetchShare(info)
                present(share, bowlID: info.bowlID, title: title)
            } catch {
                BowlSharing.shared.notice = String(localized: "The people of this bowl could not be loaded. \(error.localizedDescription)")
            }
        }
    }

    func confirmStopSharing(_ bowl: NoteFolder) {
        let bowlID = bowl.id
        ask(
            title: String(localized: "Stop Sharing “\(bowl.name)”?"),
            message: String(localized: "The people you shared it with lose access. Its entries stay with you."),
            action: String(localized: "Stop Sharing")
        ) {
            Task {
                do { try await BowlSharing.shared.stopSharing(bowlID) } catch {
                    BowlSharing.shared.notice = String(localized: "Sharing could not be stopped. \(error.localizedDescription)")
                }
            }
        }
    }

    func confirmLeave(_ bowl: NoteFolder) {
        let bowlID = bowl.id
        ask(
            title: String(localized: "Leave “\(bowl.name)”?"),
            message: String(localized: "The bowl and its entries are removed from your devices. The owner keeps them."),
            action: String(localized: "Leave Bowl")
        ) {
            Task {
                do { try await BowlSharing.shared.leave(bowlID) } catch {
                    BowlSharing.shared.notice = String(localized: "The bowl could not be left. \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Presenting

    private func present(_ share: CKShare, bowlID: UUID, title: String) {
        guard let cloud = BowlSharing.shared.cloud, let presenter = Self.topViewController() else { return }
        let controller = UICloudSharingController(share: share, container: cloud)
        controller.delegate = self
        // Invited people either see the bowl ("Can view") or add and change its entries too ("Can edit"); the owner
        // changes it for each person in this sheet. Only by invitation, never by a public link.
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        shown = (bowlID, title)
        presenter.present(controller, animated: true)
    }

    private func ask(title: String, message: String, action: String, then: @escaping () -> Void) {
        guard let presenter = Self.topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in then() })
        presenter.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: UICloudSharingControllerDelegate

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        BowlSharing.shared.notice = String(localized: "The share could not be saved. \(error.localizedDescription)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        shown?.title
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        Task { await BowlSharing.shared.refreshPeople() }
    }

    /// "Stop Sharing" (the owner) or "Remove Me" (anyone else) in the system's sheet.
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        guard let bowlID = shown?.bowlID, let info = BowlSharing.shared.info(for: bowlID) else { return }
        Task {
            if info.role == .owner {
                try? await BowlSharing.shared.stopSharing(bowlID)
            } else {
                try? await BowlSharing.shared.leave(bowlID)
            }
        }
    }
}

/// The sharing entries of a bowl's menu: share it, or see who is in it and stop sharing or leave. Only with iCloud
/// sync on; a bowl shared with me offers "Leave Bowl…" where mine offers "Delete".
struct BowlShareMenuItems: View {
    let project: NoteFolder

    var body: some View {
        if BowlSharing.isAvailable {
            if let info = BowlSharing.shared.info(for: project.id) {
                Button { BowlShareController.shared.manage(project) } label: {
                    Label("Manage Sharing…", systemImage: "person.2")
                }
                if info.role == .owner, info.endingSince == nil {
                    Button(role: .destructive) { BowlShareController.shared.confirmStopSharing(project) } label: {
                        Label("Stop Sharing…", systemImage: "person.2.slash")
                    }
                }
            } else {
                Button { BowlShareController.shared.share(project) } label: {
                    Label("Share Bowl…", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(BowlSharing.shared.preparing.contains(project.id))
            }
        }
    }
}

/// On a shared bowl's page, above its entries: who it is shared with; a tap shows the people.
struct BowlShareLine: View {
    let project: NoteFolder

    var body: some View {
        if BowlSharing.isAvailable, let info = BowlSharing.shared.info(for: project.id) {
            Button { BowlShareController.shared.manage(project) } label: {
                Label(info.summary, systemImage: "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityHint("Shows the people of the bowl")
        }
    }
}

/// The small mark of a shared bowl next to its name; an eye for one shared with me to view only, and a dot when
/// someone else added or changed something since its page was last open here.
struct BowlSharedMark: View {
    let bowlID: UUID

    var body: some View {
        if let info = BowlSharing.shared.info(for: bowlID) {
            Image(systemName: info.isReadOnly ? "eye.fill" : "person.2.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(info.role == .owner ? Text("Shared") : info.isReadOnly ? Text("Shared with you to view only") : Text("Shared with you"))
            if SharedBowlActivity.hasNewSinceLastVisit(info) {
                BowlNewMark()
            }
        }
    }
}

/// "New since your last visit": a dot in the bowl's color.
struct BowlNewMark: View {
    var body: some View {
        Circle()
            .fill(Color.brandProject)
            .frame(width: 7, height: 7)
            .accessibilityElement()
            .accessibilityLabel("New since your last visit")
            .help("New since your last visit")
    }
}

/// "New from Anna", "Changed by Ben" under an entry of a shared bowl, until it is opened here.
struct SharedActivityLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "person.crop.circle.badge.exclamationmark")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.brandProject.readable)
            .lineLimit(1)
    }
}

/// The bar button of a bowl's page: share it, or the people of a shared one.
struct BowlShareBarButton: View {
    let project: NoteFolder

    var body: some View {
        if BowlSharing.isAvailable {
            let isShared = BowlSharing.shared.isShared(project.id)
            Button {
                if isShared { BowlShareController.shared.manage(project) } else { BowlShareController.shared.share(project) }
            } label: {
                Label(isShared ? "Manage Sharing" : "Share Bowl", systemImage: isShared ? "person.2.fill" : "person.crop.circle.badge.plus")
            }
            .disabled(BowlSharing.shared.preparing.contains(project.id))
            .help(isShared ? "Manage Sharing" : "Share Bowl")
        }
    }
}

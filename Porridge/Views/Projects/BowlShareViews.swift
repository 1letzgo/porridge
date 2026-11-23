import CloudKit
import SwiftUI
import UIKit

/// Sharing a bowl on iOS. A bowl that is not shared yet goes out through the system's share sheet (`ShareLink` with
/// `BowlShareItem`): Messages, Mail or AirDrop send the invitation and add the people to the share. A shared bowl's
/// people are managed in the system's sheet for a share (`UICloudSharingController`), presented by UIKit as Apple
/// intends; inside a SwiftUI sheet it could not open Messages or Mail, so added people never got their invitation.
/// The questions before stopping or leaving are SwiftUI alerts on the root view (`BowlShareHost`).
@MainActor
@Observable
final class BowlShareController {
    static let shared = BowlShareController()

    /// The question before stopping or leaving, while it is asked.
    var question: BowlShareQuestion?
    /// Counts the closings of the system's sharing sheet. After a UIKit sheet over SwiftUI, a SwiftUI `Menu` label
    /// can come back blank (the home bar's Import); views that show one take this as their identity and redraw.
    private(set) var sheetClosings = 0

    @ObservationIgnored private let sheetDelegate = CloudSharingDelegate()

    /// The sheet of a shared bowl: who is in it, invite more, stop sharing (the owner) or leave (everyone else).
    func manage(_ bowl: NoteFolder) {
        guard let info = BowlSharing.shared.info(for: bowl.id) else { return }
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

    /// Copies the link of a shared bowl, to send some other way. Only people invited to the bowl can open it.
    func copyLink(_ bowl: NoteFolder) {
        guard let info = BowlSharing.shared.info(for: bowl.id) else { return }
        Task {
            do {
                let share = try await BowlSharing.shared.fetchShare(info)
                guard let url = share.url else { throw BowlSharingError.notShared }
                UIPasteboard.general.url = url
                BowlSharing.shared.notice = String(localized: "The link is copied. Only people invited to the bowl can open it.")
            } catch {
                BowlSharing.shared.notice = String(localized: "The link could not be loaded. \(error.localizedDescription)")
            }
        }
    }

    func confirmStopSharing(_ bowl: NoteFolder) {
        let bowlID = bowl.id
        question = BowlShareQuestion(
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
        question = BowlShareQuestion(
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
        guard let cloud = BowlSharing.shared.cloud, let presenter = Self.topViewController(),
              !(presenter is UICloudSharingController) else { return }
        let controller = BowlCloudSharingController(share: share, container: cloud)
        controller.delegate = sheetDelegate
        controller.onClose = { [weak self] in self?.sheetClosings += 1 }
        // Invited people either see the bowl ("Can view") or add and change its entries too ("Can edit"); the owner
        // changes it for each person in this sheet. Only by invitation, never by a public link.
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        sheetDelegate.shown = (bowlID, title)
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// The system's sheet for a share, telling when it is gone.
private final class BowlCloudSharingController: UICloudSharingController {
    var onClose: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}

/// Answers the system's sheet for a share.
private final class CloudSharingDelegate: NSObject, UICloudSharingControllerDelegate {
    var shown: (bowlID: UUID, title: String)?

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        let text = String(localized: "The share could not be saved. \(error.localizedDescription)")
        Task { @MainActor in BowlSharing.shared.notice = text }
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        shown?.title
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        Task { await BowlSharing.shared.refreshPeople() }
    }

    /// "Stop Sharing" (the owner) or "Remove Me" (anyone else) in the system's sheet.
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        guard let bowlID = shown?.bowlID else { return }
        Task { @MainActor in
            guard let info = BowlSharing.shared.info(for: bowlID) else { return }
            if info.role == .owner {
                try? await BowlSharing.shared.stopSharing(bowlID)
            } else {
                try? await BowlSharing.shared.leave(bowlID)
            }
        }
    }
}

/// A bowl for the system's share sheet: the share is made when a way to send it is picked, and the people the
/// invitation goes to are added to it. Only by invitation, never by a public link.
struct BowlShareItem: Transferable {
    let bowlID: UUID
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer(identifier: AudioStore.containerIdentifier)
            let options = CKAllowedSharingOptions(
                allowedParticipantPermissionOptions: .any,
                allowedParticipantAccessOptions: .specifiedRecipientsOnly
            )
            return .prepareShare(container: container, allowedSharingOptions: options) {
                try await BowlSharing.shared.share(bowlID: item.bowlID, name: item.name)
            }
        }
    }
}

/// A question with one destructive answer (and Cancel).
struct BowlShareQuestion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let then: () -> Void
}

/// Shows the questions of `BowlShareController` (on the root view).
struct BowlShareHost: ViewModifier {
    func body(content: Content) -> some View {
        let controller = BowlShareController.shared
        content
            .alert(
                controller.question?.title ?? "",
                isPresented: Binding(get: { controller.question != nil }, set: { if !$0 { controller.question = nil } }),
                presenting: controller.question
            ) { question in
                Button("Cancel", role: .cancel) {}
                Button(question.action, role: .destructive) { question.then() }
            } message: { question in
                Text(question.message)
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
                Button { BowlShareController.shared.copyLink(project) } label: {
                    Label("Copy Link", systemImage: "link")
                }
                if info.role == .owner, info.endingSince == nil {
                    Button(role: .destructive) { BowlShareController.shared.confirmStopSharing(project) } label: {
                        Label("Stop Sharing…", systemImage: "person.2.slash")
                    }
                }
            } else {
                ShareLink(item: BowlShareItem(bowlID: project.id, name: project.name), preview: SharePreview(project.name)) {
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
            Group {
                if isShared {
                    Button { BowlShareController.shared.manage(project) } label: {
                        Label("Manage Sharing", systemImage: "person.2.fill")
                    }
                } else {
                    ShareLink(item: BowlShareItem(bowlID: project.id, name: project.name), preview: SharePreview(project.name)) {
                        Label("Share Bowl", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .disabled(BowlSharing.shared.preparing.contains(project.id))
            .help(isShared ? "Manage Sharing" : "Share Bowl")
        }
    }
}

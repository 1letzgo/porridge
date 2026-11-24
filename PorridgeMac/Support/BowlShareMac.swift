import AppKit
import CloudKit

/// Sharing a bowl on the Mac: the system's sharing window for CloudKit (`NSSharingService` "cloud sharing"), the
/// questions before stopping or leaving, and the menu entries for them. Only with iCloud sync on.
@MainActor
final class BowlShareMac: NSObject, @preconcurrency NSCloudSharingServiceDelegate {
    static let shared = BowlShareMac()

    private var shown: (bowlID: UUID, title: String)?

    /// Shares the bowl (made on the first time) and opens the window to invite people.
    func share(_ bowl: NoteFolder, in window: NSWindow?) {
        let bowlID = bowl.id
        let title = bowl.name
        Task {
            do {
                let share = try await BowlSharing.shared.share(bowl)
                present(share, bowlID: bowlID, title: title, in: window)
            } catch {
                Alerts.inform(String(localized: "The Bowl Could Not Be Shared"), message: error.localizedDescription, in: window)
            }
        }
    }

    /// The people of a shared bowl: who is in it, invite more, stop sharing (the owner) or leave (everyone else).
    func manage(_ bowl: NoteFolder, in window: NSWindow?) {
        guard let info = BowlSharing.shared.info(for: bowl.id) else { return share(bowl, in: window) }
        let title = bowl.name
        Task {
            do {
                let share = try await BowlSharing.shared.fetchShare(info)
                present(share, bowlID: info.bowlID, title: title, in: window)
            } catch {
                Alerts.inform(String(localized: "The People of This Bowl Could Not Be Loaded"), message: error.localizedDescription, in: window)
            }
        }
    }

    func confirmStopSharing(_ bowl: NoteFolder, in window: NSWindow?) {
        let bowlID = bowl.id
        Alerts.confirm(
            String(localized: "Stop Sharing “\(bowl.name)”?"),
            message: String(localized: "The people you shared it with lose access. Its entries stay with you."),
            action: String(localized: "Stop Sharing"), in: window
        ) {
            Task {
                do { try await BowlSharing.shared.stopSharing(bowlID) } catch {
                    Alerts.inform(String(localized: "Sharing Could Not Be Stopped"), message: error.localizedDescription, in: window)
                }
            }
        }
    }

    func confirmLeave(_ bowl: NoteFolder, state: WindowState?, in window: NSWindow?) {
        let bowlID = bowl.id
        Alerts.confirm(
            String(localized: "Leave “\(bowl.name)”?"),
            message: String(localized: "The bowl and its entries are removed from your devices. The owner keeps them."),
            action: String(localized: "Leave Bowl"), in: window
        ) {
            if state?.page == .project(bowlID) { state?.page = .inbox }
            Task {
                do { try await BowlSharing.shared.leave(bowlID) } catch {
                    Alerts.inform(String(localized: "The Bowl Could Not Be Left"), message: error.localizedDescription, in: window)
                }
            }
        }
    }

    /// The sharing entries of a bowl's menu. A bowl shared with me offers "Leave Bowl…" in place of "Delete Bowl…"
    /// (`isSharedWithMe`), added by the caller where the delete entry would be.
    /// Copies the link of a shared bowl, to send some other way. Only people invited to the bowl can open it.
    func copyLink(_ bowl: NoteFolder, in window: NSWindow?) {
        guard let info = BowlSharing.shared.info(for: bowl.id) else { return }
        Task {
            do {
                let share = try await BowlSharing.shared.fetchShare(info)
                guard let url = share.url else { throw BowlSharingError.notShared }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                Alerts.inform(String(localized: "Link Copied"), message: String(localized: "Only people invited to the bowl can open it."), in: window)
            } catch {
                Alerts.inform(String(localized: "Sharing"), message: String(localized: "The link could not be loaded. \(error.localizedDescription)"), in: window)
            }
        }
    }

    func addItems(for bowl: NoteFolder, to menu: NSMenu, in window: NSWindow?) {
        guard BowlSharing.isAvailable else { return }
        if let info = BowlSharing.shared.info(for: bowl.id) {
            menu.add(String(localized: "Manage Sharing…"), symbol: "person.2") { self.manage(bowl, in: window) }
            if info.role == .owner, info.endingSince == nil {
                menu.add(String(localized: "Stop Sharing…"), symbol: "person.2.slash") { self.confirmStopSharing(bowl, in: window) }
            }
        } else {
            menu.add(
                String(localized: "Share Bowl…"), symbol: "person.crop.circle.badge.plus",
                enabled: !BowlSharing.shared.preparing.contains(bowl.id)
            ) { self.share(bowl, in: window) }
        }
    }

    // MARK: Presenting

    private func present(_ share: CKShare, bowlID: UUID, title: String, in window: NSWindow?) {
        guard let cloud = BowlSharing.shared.cloud, let service = NSSharingService(named: .cloudSharing) else { return }
        let provider = NSItemProvider()
        provider.registerCloudKitShare(share, container: cloud)
        guard service.canPerform(withItems: [provider]) else {
            Alerts.inform(String(localized: "Sharing Is Not Available"), message: String(localized: "Check that this Mac is signed in to iCloud."), in: window)
            return
        }
        shown = (bowlID, title)
        service.delegate = self
        service.subject = title
        service.perform(withItems: [provider])
    }

    // MARK: NSCloudSharingServiceDelegate

    /// Invited people either see the bowl ("Can view") or add and change its entries too ("Can edit"); the owner
    /// changes it for each person in this window. Only by invitation, never by a public link.
    func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadOnly, .allowReadWrite]
    }

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        Task { await BowlSharing.shared.refreshPeople() }
    }

    /// "Stop Sharing" (the owner) or "Remove Me" (anyone else) in the system's window.
    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        guard let bowlID = shown?.bowlID, let info = BowlSharing.shared.info(for: bowlID) else { return }
        Task {
            if info.role == .owner {
                try? await BowlSharing.shared.stopSharing(bowlID)
            } else {
                try? await BowlSharing.shared.leave(bowlID)
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        if let error, (error as? CKError)?.code != .operationCancelled, (error as NSError).code != NSUserCancelledError {
            Alerts.inform(String(localized: "The Share Could Not Be Saved"), message: error.localizedDescription, in: nil)
        }
        Task { await BowlSharing.shared.refreshPeople() }
    }
}

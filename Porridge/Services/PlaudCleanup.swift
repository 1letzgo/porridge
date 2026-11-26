import Foundation
import WebKit

/// The Plaud import is gone. Once per device this removes what it left behind: the sign-in in the Keychain
/// (token, key and device signatures), its settings, its half-finished downloads and the cookies of its sign-in page.
/// Entries imported from Plaud stay as they are.
@MainActor
enum PlaudCleanup {
    private static let doneKey = "plaudCleanupDone"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        Keychain.set(nil, for: "plaud.account")
        defaults.removeObject(forKey: "plaud.importedSessions")
        defaults.removeObject(forKey: "lastHandshakenPeripheralId")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("Plaud", isDirectory: true))
        defaults.set(true, forKey: doneKey)
        Task { await removeSignInCookies() }
    }

    private static func removeSignInCookies() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let plaud = records.filter { $0.displayName.lowercased().contains("plaud") }
        if !plaud.isEmpty { await store.removeData(ofTypes: types, for: plaud) }
        for cookie in await store.httpCookieStore.allCookies() where cookie.domain.lowercased().contains("plaud") {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }
}

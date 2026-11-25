import Foundation
import Security

/// Stores secrets in the iCloud Keychain so they are available on all of the user's devices.
/// A build without iCloud rights (e.g. a local test build on the Mac) falls back to a local keychain item.
enum Keychain {
    private static let service = "de.letzgo.porridge"

    /// Where an item can live: synced (iCloud Keychain) or only on this device.
    private enum Store: CaseIterable {
        case synced
        case local

        func attributes(_ account: String) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            switch self {
            case .synced:
                query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                query[kSecUseDataProtectionKeychain as String] = true
            case .local:
                break
            }
            return query
        }
    }

    #if os(macOS) && DEBUG
    /// Test runs of the Mac app (`PORRIDGE_TEST_DATA`) never see the owner's secrets (model keys, Plaud account):
    /// what they store lives in memory for the run (`TestDefaults`).
    nonisolated(unsafe) private static var testItems: [String: String] = [:]
    private static var usesTestItems: Bool { DataLocation.testFolder != nil }
    #endif

    static func get(_ account: String) -> String? {
        #if os(macOS) && DEBUG
        if usesTestItems { return testItems[account] }
        #endif
        for store in Store.allCases {
            var query = store.attributes(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    static func set(_ value: String?, for account: String) {
        #if os(macOS) && DEBUG
        if usesTestItems {
            testItems[account] = value.flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        #endif
        guard let value, !value.isEmpty else {
            for store in Store.allCases { SecItemDelete(store.attributes(account) as CFDictionary) }
            return
        }
        let data = Data(value.utf8)
        // The old secret is only replaced, never deleted first: a failed write would leave nothing.
        for store in Store.allCases {
            let status = SecItemUpdate(store.attributes(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
        }
        for store in Store.allCases {
            var item = store.attributes(account)
            if store == .synced { item[kSecAttrSynchronizable as String] = true }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            item[kSecValueData as String] = data
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
        }
    }
}

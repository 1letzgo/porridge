import Foundation

/// Everything the Plaud import keeps between uses: the login token, your encryption key and the device signatures.
/// Stored in the Keychain (it syncs through iCloud Keychain, so the Mac and iPhone share one sign-in).
struct PlaudAccount: Codable {
    var userToken: String?
    /// The `pld_urt` cookie: renews `userToken` once it has expired.
    var refreshToken: String?
    var apiHost = "https://api.plaud.ai"
    /// RSA key from Plaud (PKCS#8 PEM); the recorder encrypts everything to it.
    var privatePEM: String?
    var publicPEM: String?
    /// Serial number -> base64 signature of that device.
    var signatures: [String: String] = [:]
    var lastSerial: String?

    private static let account = "plaud.account"

    static func load() -> PlaudAccount {
        guard let text = Keychain.get(account), let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(PlaudAccount.self, from: data) else { return PlaudAccount() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.set(text, for: Self.account)
    }

    static func clear() {
        Keychain.set(nil, for: account)
    }
}

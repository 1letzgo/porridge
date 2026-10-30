import Foundation

/// The Nextcloud account the app syncs with: server, user and an app password of its own (from the login in
/// the browser, Login Flow v2), never the user's main password.
struct NextcloudAccount: Equatable {
    var server: URL
    var loginName: String
    var appPassword: String

    private static let serverKey = "nextcloudServer"
    private static let loginKey = "nextcloudLogin"
    private static let passwordKey = "nextcloudAppPassword"

    static var saved: NextcloudAccount? {
        guard let server = UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:)),
              let login = UserDefaults.standard.string(forKey: loginKey),
              let password = Keychain.get(passwordKey) else { return nil }
        return NextcloudAccount(server: server, loginName: login, appPassword: password)
    }

    func save() {
        UserDefaults.standard.set(server.absoluteString, forKey: Self.serverKey)
        UserDefaults.standard.set(loginName, forKey: Self.loginKey)
        Keychain.set(appPassword, for: Self.passwordKey)
    }

    static func remove() {
        UserDefaults.standard.removeObject(forKey: serverKey)
        UserDefaults.standard.removeObject(forKey: loginKey)
        Keychain.set(nil, for: passwordKey)
    }

    /// Shown in the settings: "anna @ cloud.example.com".
    var label: String { "\(loginName) @ \(server.host() ?? server.absoluteString)" }
}

enum NextcloudError: LocalizedError {
    case badServer
    case http(Int)
    case loginTimedOut
    /// The file changed on the server since it was read (another device synced in between).
    case conflict

    var errorDescription: String? {
        switch self {
        case .badServer: "This does not look like a Nextcloud server."
        case .http(401): "Nextcloud refused the login. Connect again."
        case let .http(code): "Nextcloud answered with error \(code)."
        case .loginTimedOut: "The login in the browser was not finished in time."
        case .conflict: "The sync file changed in the meantime."
        }
    }
}

/// Login Flow v2: the app asks the server for a login page, the user confirms it in the browser, and the app
/// picks up an app password by polling.
enum NextcloudLogin {
    struct Pending {
        let loginURL: URL
        let pollURL: URL
        let token: String
    }

    /// Accepts "cloud.example.com", "https://cloud.example.com/" or a full URL with a path.
    static func normalize(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/index.php") { text.removeLast("/index.php".count) }
        return URL(string: text)
    }

    static func start(server: URL) async throws -> Pending {
        var request = URLRequest(url: server.appending(path: "index.php/login/v2"))
        request.httpMethod = "POST"
        request.setValue("Porridge", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poll = json["poll"] as? [String: Any],
              let token = poll["token"] as? String,
              let endpoint = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
              let login = (json["login"] as? String).flatMap(URL.init(string:)) else { throw NextcloudError.badServer }
        return Pending(loginURL: login, pollURL: endpoint, token: token)
    }

    /// Polls every two seconds for up to 20 minutes (the lifetime of the token).
    static func finish(_ pending: Pending) async throws -> NextcloudAccount {
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: pending.pollURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(pending.token)".utf8)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let server = json["server"].flatMap(NextcloudLogin.normalize),
               let login = json["loginName"], let password = json["appPassword"] {
                return NextcloudAccount(server: server, loginName: login, appPassword: password)
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw NextcloudError.loginTimedOut
    }
}

/// The few WebDAV calls the sync needs, in the folder "Porridge" of the user's files.
struct WebDAV {
    let account: NextcloudAccount

    /// …/remote.php/dav/files/<user>/Porridge/
    var root: URL {
        account.server
            .appending(path: "remote.php/dav/files")
            .appending(path: account.loginName)
            .appending(path: "Porridge", directoryHint: .isDirectory)
    }

    var recordings: URL { root.appending(path: "Recordings", directoryHint: .isDirectory) }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        let credentials = Data("\(account.loginName):\(account.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("Porridge", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

    /// The file and its ETag; nil when it does not exist yet.
    func get(_ url: URL) async throws -> (data: Data, etag: String?)? {
        let (data, response) = try await URLSession.shared.data(for: request(url, method: "GET"))
        switch status(response) {
        case 200: return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
        case 404: return nil
        case let code: throw NextcloudError.http(code)
        }
    }

    /// Writes the file only if it is still the one read (`etag`), or does not exist yet (`etag` nil).
    func put(_ data: Data, to url: URL, ifMatch etag: String?) async throws {
        var request = request(url, method: "PUT")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") } else { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        switch status(response) {
        case 200...299: return
        case 412: throw NextcloudError.conflict
        case let code: throw NextcloudError.http(code)
        }
    }

    func upload(file: URL, to url: URL) async throws {
        let (_, response) = try await URLSession.shared.upload(for: request(url, method: "PUT"), fromFile: file)
        guard (200...299).contains(status(response)) else { throw NextcloudError.http(status(response)) }
    }

    func download(_ url: URL, to file: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(for: request(url, method: "GET"))
        guard status(response) == 200 else { throw NextcloudError.http(status(response)) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
    }

    /// Creates the folder; an existing one is fine.
    func makeFolder(_ url: URL) async throws {
        let (_, response) = try await URLSession.shared.data(for: request(url, method: "MKCOL"))
        guard [201, 405].contains(status(response)) else { throw NextcloudError.http(status(response)) }
    }

    /// Names of the files directly in a folder.
    func list(_ url: URL) async throws -> Set<String> {
        var request = request(url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if status(response) == 404 { return [] }
        guard status(response) == 207 else { throw NextcloudError.http(status(response)) }
        // The folder itself comes back too, with a trailing slash.
        return Set(HrefParser(data: data).hrefs.compactMap { href in
            let path = href.removingPercentEncoding ?? href
            return path.hasSuffix("/") ? nil : (path as NSString).lastPathComponent
        })
    }
}

/// Collects the `<d:href>` values of a PROPFIND answer.
private final class HrefParser: NSObject, XMLParserDelegate {
    var hrefs: [String] = []
    private var current: String?

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "href" { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current? += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "href", let current { hrefs.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if name == "href" { current = nil }
    }
}

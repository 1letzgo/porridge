// Ported from roopen219/plaude-archiver (MIT License, https://github.com/roopen219/plaude-archiver):
// the Plaud Note Pro Bluetooth protocol and file format, reverse-engineered there.
import Foundation

enum PlaudAPIError: Error, CustomStringConvertible {
    case message(String)
    /// Plaud no longer accepts the user token (HTTP 401/403): the sign-in has expired.
    case unauthorized
    var description: String {
        switch self {
        case .message(let m): return m
        case .unauthorized: return "Your Plaud sign-in has expired. Please sign in again."
        }
    }
}

// Talks to the Plaud device endpoints with the UT token.
// Mirrors the app: X-Encrypt-Response: 1, Fernet-decrypt replies, follow the -302 region redirect.
struct PlaudAPI {
    var userToken: String
    var host: String

    /// Cookies are sent by hand (the refresh call), never stored or replayed by the session.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private func decodeEnvelope(_ resp: HTTPURLResponse, _ body: Data) throws -> [String: Any] {
        var text = String(data: body, encoding: .utf8) ?? ""
        if resp.value(forHTTPHeaderField: "x-encrypt-response") == "1" {
            text = String(data: try PlaudCrypto.fernetDecrypt(text), encoding: .utf8) ?? ""
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw PlaudAPIError.message("bad JSON from \(resp.url?.path ?? "?")")
        }
        return obj
    }

    // Returns the parsed envelope, following a one-shot region redirect and updating `host`.
    private func call(_ method: String, _ path: String, body: [String: Any]?,
                      headers: [String: String] = [:]) async throws
        -> (json: [String: Any], host: String, response: HTTPURLResponse)
    {
        var currentHost = host
        for _ in 0..<2 {
            guard let url = URL(string: currentHost + path) else {
                throw PlaudAPIError.message("bad API host: \(currentHost)")
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer " + userToken, forHTTPHeaderField: "Authorization")
            req.setValue("web", forHTTPHeaderField: "app-platform")
            req.setValue("web", forHTTPHeaderField: "edit-from")
            req.setValue("1", forHTTPHeaderField: "X-Encrypt-Response")
            for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await Self.session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PlaudAPIError.message("no HTTP response") }
            if http.statusCode == 401 || http.statusCode == 403 { throw PlaudAPIError.unauthorized }
            let json = try decodeEnvelope(http, data)
            let status = (json["status"] as? Int) ?? (json["code"] as? Int)
            if status == -302, let domains = (json["data"] as? [String: Any])?["domains"] as? [String: Any],
               let api = domains["api"] as? String {
                currentHost = api
                continue
            }
            if status == 401 || status == 403 { throw PlaudAPIError.unauthorized }
            return (json, currentHost, http)
        }
        throw PlaudAPIError.message("region redirect loop")
    }

    // MARK: Token renewal

    /// What a renewal gives back: the new user token, the new refresh token (the old one stays valid
    /// when the server sent none) and the regional host that answered.
    struct RenewedTokens {
        var userToken: String
        var refreshToken: String?
        var host: String
    }

    // POST /auth/refresh-user-token with the pld_ut + pld_urt cookies -> fresh cookies in Set-Cookie.
    // This is what web.plaud.ai does when the user token runs out; the new token comes back as a cookie,
    // not in the body (the body carries only token_id and the lifetimes).
    func refreshUserToken(refreshToken: String) async throws -> RenewedTokens {
        let cookieHeader = "pld_ut=\(userToken); pld_urt=\(refreshToken)"
        let (json, h, http) = try await call("POST", "/auth/refresh-user-token", body: [:],
                                             headers: ["Cookie": cookieHeader, "Origin": "https://web.plaud.ai"])
        guard ((json["status"] as? Int) ?? -1) == 0 else {
            throw PlaudAPIError.message("refresh-user-token: \(json["msg"] ?? json)")
        }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { fields[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? URL(string: h)!)
        let newUT = cookies.first(where: { $0.name == "pld_ut" && !$0.value.isEmpty })?.value
            ?? (json["data"] as? [String: Any])?["access_token"] as? String
        guard let newUT else { throw PlaudAPIError.message("refresh-user-token: no new token in the reply") }
        let newURT = cookies.first(where: { $0.name == "pld_urt" && !$0.value.isEmpty })?.value
        return RenewedTokens(userToken: newUT, refreshToken: newURT, host: h)
    }

    // POST /device-app/device/sn-sign -> base64 signature for the serial.
    func snSign(serial: String) async throws -> (sig: String, host: String) {
        let (json, h, _) = try await call("POST", "/device-app/device/sn-sign", body: ["sns": [serial]])
        guard ((json["status"] as? Int) ?? -1) == 0,
              let sig = ((json["data"] as? [String: Any])?["signature"] as? [String: Any])?[serial] as? String
        else { throw PlaudAPIError.message("sn-sign: \(json["msg"] ?? json)") }
        return (sig, h)
    }

    // POST /device-app/e2ee/gen_key -> (privatePEM, publicPEM).
    func genKey() async throws -> (priv: String, pub: String, host: String) {
        let (json, h, _) = try await call("POST", "/device-app/e2ee/gen_key", body: [:])
        guard ((json["status"] as? Int) ?? -1) == 0, let data = json["data"] as? [String: Any],
              let privB64 = data["private_key_base64"] as? String,
              let pubB64 = data["public_key_base64"] as? String,
              let priv = Data(base64Encoded: privB64).flatMap({ String(data: $0, encoding: .utf8) }),
              let pub = Data(base64Encoded: pubB64).flatMap({ String(data: $0, encoding: .utf8) })
        else { throw PlaudAPIError.message("gen_key: \(json["msg"] ?? json)") }
        return (priv, pub, h)
    }

    // Region from the UT token's JWT `region` claim, e.g. aws:ap-southeast-1 -> api-apse1.plaud.ai.
    static func hostFromToken(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = PlaudCrypto.base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let region = obj["region"] as? String else { return "https://api.plaud.ai" }
        let map = ["aws:ap-southeast-1": "apse1", "aws:us-east-1": "use1",
                   "aws:eu-central-1": "euc1", "aws:us-west-2": "usw2"]
        if let sub = map[region] { return "https://api-\(sub).plaud.ai" }
        return "https://api.plaud.ai"
    }

    // The `sub` claim is the user_id, which is also the BLE bind token.
    static func subject(of token: String) -> String? {
        claims(of: token)?["sub"] as? String
    }

    /// When the token stops being accepted, from its JWT `exp` claim. nil when it is not a JWT.
    static func expiry(of token: String) -> Date? {
        guard let exp = claims(of: token)?["exp"] else { return nil }
        if let seconds = exp as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = exp as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        return nil
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = PlaudCrypto.base64urlDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }
}

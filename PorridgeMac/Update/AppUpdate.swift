import AppKit
import Foundation
import Observation

/// Looks for a newer Mac version among the GitHub releases of the app (tags `mac-v<version>`, see
/// scripts/release-mac.sh). Checks shortly after launch and every few hours; the user can also ask.
@MainActor
@Observable
final class AppUpdate {
    static let shared = AppUpdate()

    struct Release: Equatable {
        let version: String
        let tag: String
        let pageURL: URL
        /// The zip of the app, when the release has one.
        let downloadURL: URL?
        let notes: String
    }

    /// Where the releases live. Reading them needs no token as long as the repository is public.
    static let repository = "1letzgo/porridge"
    private static let tagPrefix = "mac-v"
    private static let skippedKey = "updateSkippedTag"
    private static let interval: TimeInterval = 6 * 60 * 60

    /// A newer version than the running one (not the one the user skipped).
    private(set) var available: Release?
    private(set) var checking = false
    /// What the last check found, for the Settings: nil until the first check.
    private(set) var lastResult: String?
    private(set) var lastChecked: Date?

    @ObservationIgnored private var timer: Task<Void, Never>?

    private init() {}

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts the periodic check (a moment after launch, then every few hours).
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.check(manual: false)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// `manual`: asked by the user, so a skipped version counts again and the result is reported either way.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let releases = try await Self.fetchReleases()
            lastChecked = Date()
            let newer = releases
                .filter { Self.isNewer($0.version, than: Self.currentVersion) }
                .max { Self.compare($0.version, $1.version) == .orderedAscending }
            if manual { UserDefaults.standard.removeObject(forKey: Self.skippedKey) }
            if let newer, newer.tag != UserDefaults.standard.string(forKey: Self.skippedKey) {
                available = newer
                lastResult = "Version \(newer.version) is available."
            } else {
                available = nil
                lastResult = "Porridge \(Self.currentVersion) is up to date."
            }
        } catch {
            lastResult = "Could not check: \(error.localizedDescription)"
        }
    }

    /// Opens the zip in the browser (it downloads), or the release page when there is no zip.
    func download() {
        guard let available else { return }
        NSWorkspace.shared.open(available.downloadURL ?? available.pageURL)
    }

    func skip() {
        guard let available else { return }
        UserDefaults.standard.set(available.tag, forKey: Self.skippedKey)
        self.available = nil
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static func fetchReleases() async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Porridge-mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "AppUpdate", code: code, userInfo: [
                NSLocalizedDescriptionKey: code == 404 ? "The releases are not public." : "GitHub answered \(code).",
            ])
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
            .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(tagPrefix) }
            .map { release in
                Release(
                    version: String(release.tag_name.dropFirst(tagPrefix.count)),
                    tag: release.tag_name,
                    pageURL: release.html_url,
                    downloadURL: release.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url,
                    notes: release.body ?? ""
                )
            }
    }

    // MARK: - Versions

    /// "0.10.1" > "0.9.3": compared number by number, missing parts count as 0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        compare(version, current) == .orderedDescending
    }
}

import AppKit
import WebKit

/// Signing in to Plaud: web.plaud.ai in a sheet, which waits for the login cookies (`pld_ut`, and `pld_urt` for
/// renewals). Nothing is read from the page itself. Google and Apple sign-in open a popup window, so the web view
/// creates popups over itself.
@MainActor
enum PlaudLogin {
    static func present(in window: NSWindow?, onToken: @escaping (String, String?) -> Void) {
        let controller = PlaudLoginViewController(onToken: onToken)
        if let content = window?.contentViewController {
            content.presentAsSheet(controller)
        } else {
            let panel = NSWindow(contentViewController: controller)
            panel.title = "Plaud Sign-In"
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Signing out: without this the cookies of the last sign-in are still there, and the next sign-in would find
    /// them at once and sign in to the same account again.
    static func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.lowercased().contains("plaud") })
        for cookie in await store.httpCookieStore.allCookies() where cookie.domain.lowercased().contains("plaud") {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    /// The `pld_ut` cookie, unless it is a JWT that has already expired.
    static func validUserToken(in cookies: [HTTPCookie]) -> String? {
        for cookie in cookies where cookie.name == "pld_ut" && !cookie.value.isEmpty {
            if let expiry = PlaudAPI.expiry(of: cookie.value), expiry.timeIntervalSinceNow < 60 { continue }
            return cookie.value
        }
        return nil
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

private final class PlaudLoginViewController: NSViewController, WKUIDelegate, WKNavigationDelegate {
    private let onToken: (String, String?) -> Void
    private var watch: Task<Void, Never>?
    private var web: WKWebView!

    init(onToken: @escaping (String, String?) -> Void) {
        self.onToken = onToken
        super.init(nibName: nil, bundle: nil)
        title = "Plaud Sign-In"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = PlaudLogin.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.load(URLRequest(url: URL(string: "https://web.plaud.ai/")!))

        let heading = NSTextField.label("Plaud Sign-In", font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .bold))
        let cancel = ActionButton(title: "Cancel") { [weak self] in self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView.horizontal([cancel, NSView(), heading, NSView()], spacing: 8)
        let root = NSView()
        root.addSubview(bar)
        root.addSubview(web)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 640),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                if let token = PlaudLogin.validUserToken(in: cookies) {
                    let refresh = cookies.first(where: { $0.name == "pld_urt" && !$0.value.isEmpty })?.value
                    self?.onToken(token, refresh)
                    self?.dismiss(nil)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        watch?.cancel()
    }

    // The popup must be created with the configuration handed in, or it has no `window.opener`.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.customUserAgent = PlaudLogin.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        popup.autoresizingMask = [.width, .height]
        webView.addSubview(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
    }

    // A plain `target="_blank"` link (terms, privacy policy) opens in the same view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, webView.superview === view {
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// The recordings on a Plaud recorder: each can be copied into Porridge as a meeting, or all new ones at once.
final class PlaudImportViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let importer = PlaudImporter()
    private let onImport: (PlaudImportedAudio) -> Void
    private var observing: Observing?
    private var recordings: [PlaudRecording] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = EmptyMessageView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .secondaryLabelColor, lines: 0)
    private let tip = NSTextField.label("Wake the recorder with its button. Close the Plaud app if it is open.", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private let primary = PillButton(title: "", tint: .brandSky, target: nil, action: nil)
    private let reload = ActionButton(title: "Reload", symbol: "arrow.clockwise") {}
    private let done = ActionButton(title: "Done") {}
    private var shownError: String?

    init(onImport: @escaping (PlaudImportedAudio) -> Void) {
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
        title = "Plaud"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField.label("Plaud", font: .systemFont(ofSize: 17, weight: .bold))
        let column = NSTableColumn(identifier: .init("recording"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Recordings")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        status.alignment = .center
        tip.alignment = .center
        primary.isFilled = true
        primary.target = self
        primary.action = #selector(primaryAction)
        reload.setHandler { [weak self] in self?.refresh() }
        done.setHandler { [weak self] in self?.dismiss(nil) }
        done.keyEquivalent = "\r"
        let waiting = NSStackView.vertical([empty, spinner, status, tip], spacing: 12, alignment: .centerX)
        let buttons = NSStackView.horizontal([reload, NSView(), done], spacing: 8)
        let stack = NSStackView.vertical([heading, scroll, waiting, primary, buttons], spacing: 14, alignment: .centerX)
        let root = NSView()
        root.addSubview(stack)
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor),
            empty.heightAnchor.constraint(equalToConstant: 180),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tip.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in self?.render() }
        if importer.signedIn { refresh() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observing?.cancel()
        importer.disconnect()
    }

    private func refresh() {
        Task { @MainActor in await importer.refresh() }
    }

    private var newRecordings: [PlaudRecording] { importer.recordings.filter { !$0.imported } }

    private func render() {
        let busy = importer.importingId != nil
        done.isEnabled = !busy
        reload.isHidden = !importer.signedIn
        reload.isEnabled = !busy
        if recordings != importer.recordings || busy {
            recordings = importer.recordings
            table.reloadData()
        } else {
            _ = importer.progress
        }
        if !importer.signedIn {
            scroll.isHidden = true
            empty.isHidden = false
            empty.show(title: "Plaud Recorder", message: "Sign in to Plaud once. After that the recordings come straight from the recorder over Bluetooth.", symbol: "waveform")
            spinner.stopAnimation(nil)
            status.isHidden = true
            tip.isHidden = true
            primary.isHidden = false
            primary.title = "Sign In to Plaud"
        } else if importer.recordings.isEmpty {
            scroll.isHidden = true
            primary.isHidden = importer.isWorking
            primary.title = "Try Again"
            if importer.isWorking {
                empty.isHidden = true
                spinner.startAnimation(nil)
                status.isHidden = false
                status.stringValue = importer.status.isEmpty ? "Connecting…" : importer.status
                tip.isHidden = false
            } else {
                spinner.stopAnimation(nil)
                status.isHidden = true
                tip.isHidden = true
                empty.isHidden = false
                empty.show(
                    title: importer.status.isEmpty ? "No Recorder Found" : "Nothing to Import",
                    message: importer.status.isEmpty ? "Wake the recorder with its button and try again." : importer.status,
                    symbol: "waveform"
                )
            }
        } else {
            scroll.isHidden = false
            empty.isHidden = true
            spinner.stopAnimation(nil)
            status.isHidden = true
            tip.isHidden = true
            let count = newRecordings.count
            primary.isHidden = count == 0
            primary.title = count == 1 ? "Import 1 Recording" : "Import \(count) Recordings"
            primary.isEnabled = !busy
            // The progress of the one being imported.
            if let id = importer.importingId, let row = recordings.firstIndex(where: { $0.sessionId == id }) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaudRecordingCell)?.progress = importer.progress
            }
        }
        if let error = importer.errorMessage, error != shownError {
            shownError = error
            Alerts.inform("Plaud Import Failed", message: error, in: view.window)
            importer.errorMessage = nil
        }
    }

    @objc private func primaryAction() {
        if !importer.signedIn {
            PlaudLogin.present(in: view.window) { [weak self] token, refresh in
                self?.importer.signIn(token: token, refreshToken: refresh)
                NotificationCenter.default.post(name: .plaudAccountChanged, object: nil)
                self?.refresh()
            }
        } else if importer.recordings.isEmpty {
            refresh()
        } else {
            Task { @MainActor in
                for recording in newRecordings {
                    guard let audio = await importer.importRecording(recording) else { return }
                    onImport(audio)
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recordings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let recording = recordings[row]
        let cell = PlaudRecordingCell(recording: recording, isImporting: importer.importingId == recording.sessionId, canImport: importer.importingId == nil)
        cell.progress = importer.progress
        cell.onImport = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if let audio = await self.importer.importRecording(recording) { self.onImport(audio) }
            }
        }
        cell.onStop = { [weak self] in self?.importer.cancelImport() }
        return cell
    }
}

private final class PlaudRecordingCell: NSTableCellView {
    var onImport: (() -> Void)?
    var onStop: (() -> Void)?
    private let bar = NSProgressIndicator()
    var progress: Double = 0 { didSet { bar.doubleValue = progress } }

    init(recording: PlaudRecording, isImporting: Bool, canImport: Bool) {
        super.init(frame: .zero)
        let date = NSTextField.label(recording.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()), font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold), color: .brandNavy)
        let size = NSTextField.label(ByteCountFormatter.string(fromByteCount: Int64(recording.size), countStyle: .file), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = !isImporting
        let text = NSStackView.vertical([date, size, bar], spacing: 4)
        let trailing: NSView
        if isImporting {
            trailing = ActionButton(title: "Stop") { [weak self] in self?.onStop?() }
        } else if recording.imported {
            let check = NSImageView(image: .symbol("checkmark.circle.fill", size: 18, label: "Imported"))
            check.contentTintColor = .brandSkyText
            trailing = check
        } else {
            let button = ActionButton(title: "Import") { [weak self] in self?.onImport?() }
            button.isEnabled = canImport
            trailing = button
        }
        let row = NSStackView.horizontal([text, NSView(), trailing], spacing: 10)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6))
        bar.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

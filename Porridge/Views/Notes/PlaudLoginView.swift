import SwiftUI
import WebKit

/// Shows web.plaud.ai and waits for the login cookies (`pld_ut`, and `pld_urt` for renewals).
/// Nothing is read from the page itself.
///
/// Google and Apple sign-in on web.plaud.ai open a popup window (`ux_mode: "popup"` / `usePopup: true`),
/// so the web view needs a `WKUIDelegate` that creates the popup; without one those buttons do nothing.
struct PlaudLoginView: View {
    /// The user token (`pld_ut`) and, when the site set one, the refresh token (`pld_urt`).
    var onToken: (_ token: String, _ refreshToken: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlaudWebView()
                .ignoresSafeArea(edges: .bottom)
                .brandNavigationTitle("Plaud Sign-In")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task {
                    while !Task.isCancelled {
                        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                        if let token = Self.validUserToken(in: cookies) {
                            let refresh = cookies.first(where: { $0.name == "pld_urt" && !$0.value.isEmpty })?.value
                            onToken(token, refresh)
                            dismiss()
                            return
                        }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }

    /// The `pld_ut` cookie, unless it is a JWT that has already expired (a stale cookie from an
    /// earlier sign-in; the site renews it through `pld_urt` once the page has loaded).
    static func validUserToken(in cookies: [HTTPCookie]) -> String? {
        for cookie in cookies where cookie.name == "pld_ut" && !cookie.value.isEmpty {
            if let expiry = PlaudAPI.expiry(of: cookie.value), expiry.timeIntervalSinceNow < 60 { continue }
            return cookie.value
        }
        return nil
    }
}

private let plaudUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
private let plaudLoginURL = URL(string: "https://web.plaud.ai/")!

/// Creates the main web view and the popup web views the sign-in buttons open.
/// A popup is laid over the main web view and removed when the page closes it (`window.close()`).
private final class PlaudWebCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The popup must be created with the configuration handed in, or it has no `window.opener`
        // and the sign-in result never reaches the page.
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.customUserAgent = plaudUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        #if os(iOS)
        popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        popup.autoresizingMask = [.width, .height]
        #endif
        webView.addSubview(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
    }

    // A plain `target="_blank"` link (terms, privacy policy) opens in the same view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, webView.superview == nil {
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

private func makePlaudWebView(coordinator: PlaudWebCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()   // persistent: a prior sign-in is remembered
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.customUserAgent = plaudUserAgent
    web.uiDelegate = coordinator
    web.navigationDelegate = coordinator
    web.load(URLRequest(url: plaudLoginURL))
    return web
}

#if os(iOS)
private struct PlaudWebView: UIViewRepresentable {
    func makeCoordinator() -> PlaudWebCoordinator { PlaudWebCoordinator() }
    func makeUIView(context: Context) -> WKWebView { makePlaudWebView(coordinator: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct PlaudWebView: NSViewRepresentable {
    func makeCoordinator() -> PlaudWebCoordinator { PlaudWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView { makePlaudWebView(coordinator: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

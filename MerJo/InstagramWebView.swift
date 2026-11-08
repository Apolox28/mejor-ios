import SwiftUI
import WebKit

/// Todas las pestañas comparten cookies, así que inicias sesión una sola vez.
enum SharedWeb {
    static let processPool = WKProcessPool()
    static let dataStore = WKWebsiteDataStore.default()

    static let allowedHosts = [
        "instagram.com", "cdninstagram.com", "facebook.com",
        "fbcdn.net", "fb.com", "fbsbx.com", "accountscenter.instagram.com"
    ]

    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

struct InstagramWebView: UIViewRepresentable {
    let section: Section
    @Binding var reselect: Section?

    func makeCoordinator() -> Coordinator { Coordinator(section: section) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = SharedWeb.processPool
        config.websiteDataStore = SharedWeb.dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Hace que Instagram nos trate como Safari móvil.
        config.applicationNameForUserAgent = "Version/16.0 Mobile/15E148 Safari/604.1"

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: "window.__merjoSection = '\(section.rawValue)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: FocusFilter.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        context.coordinator.webView = webView
        webView.load(URLRequest(url: section.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if reselect == section {
            DispatchQueue.main.async { reselect = nil }
            webView.load(URLRequest(url: section.startURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let section: Section
        weak var webView: WKWebView?

        init(section: Section) { self.section = section }

        @objc func refresh(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""

            if ["about", "blob", "data"].contains(scheme) { return decisionHandler(.allow) }

            // Enlaces a otros sitios se abren en Safari, no dentro de la app.
            if (scheme != "http" && scheme != "https") || !SharedWeb.isAllowed(url) {
                if action.targetFrame?.isMainFrame ?? true {
                    UIApplication.shared.open(url)
                    return decisionHandler(.cancel)
                }
                return decisionHandler(.allow)
            }

            // Bloqueo de secciones adictivas en cargas completas de página.
            if action.targetFrame?.isMainFrame == true,
               let redirect = FocusFilter.redirect(for: url) {
                webView.load(URLRequest(url: redirect))
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // Enlaces con target="_blank": se abren en la misma vista.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if SharedWeb.isAllowed(url) { webView.load(URLRequest(url: url)) }
                else { UIApplication.shared.open(url) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
        }
    }
}

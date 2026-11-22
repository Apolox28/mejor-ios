import SwiftUI
import WebKit

/// La web solo se usa para iniciar sesión en la página oficial. Sus cookies
/// son las que después usa el cliente nativo (InstagramAPI).
enum SharedWeb {
    static let processPool = WKProcessPool()
    static let dataStore = WKWebsiteDataStore.default()

    static let allowedHosts = [
        "instagram.com", "cdninstagram.com", "facebook.com",
        "fbcdn.net", "fb.com", "fbsbx.com", "meta.com"
    ]

    /// Esquemas que intentan abrir la app oficial o la App Store: se ignoran.
    static let blockedSchemes = ["instagram", "instagram-stories", "fb", "fb-messenger",
                                 "itms", "itms-apps", "itms-appss", "intent"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Identidad de Safari para iPhone con la versión real del sistema.
    static let userAgent: String = {
        let version = UIDevice.current.systemVersion
        let parts = version.split(separator: ".")
        let major = parts.first.map(String.init) ?? "15"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        let osToken = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }()
}

/// Página de inicio de sesión con indicador de carga.
struct WebScreen: View {
    let startURL: URL
    let resetToken: Int
    var onNavigate: ((URL) -> Void)? = nil

    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            LoginWebView(startURL: startURL, resetToken: resetToken,
                         isLoading: $isLoading, onNavigate: onNavigate)
                .opacity(isLoading ? 0 : 1)
            if isLoading { ProgressView().scaleEffect(1.2) }
        }
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }
}

private struct LoginWebView: UIViewRepresentable {
    let startURL: URL
    let resetToken: Int
    @Binding var isLoading: Bool
    var onNavigate: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = SharedWeb.processPool
        config.websiteDataStore = SharedWeb.dataStore
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.userContentController.addUserScript(WKUserScript(
            source: FocusFilter.loginScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SharedWeb.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.lastToken = resetToken
        context.coordinator.urlObservation = webView.observe(\.url, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            guard let url = view.url else { return }
            DispatchQueue.main.async { coordinator?.parent.onNavigate?(url) }
        }
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            webView.load(URLRequest(url: startURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LoginWebView
        var lastToken = 0
        var urlObservation: NSKeyValueObservation?
        private weak var popupController: UIViewController?

        init(parent: LoginWebView) { self.parent = parent }

        private func finishLoading() {
            DispatchQueue.main.async { if self.parent.isLoading { self.parent.isLoading = false } }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "blob", "data", "javascript"].contains(scheme) { return decisionHandler(.allow) }
            if SharedWeb.blockedSchemes.contains(scheme) { return decisionHandler(.cancel) }
            if (scheme != "http" && scheme != "https") || !SharedWeb.isAllowed(url) {
                if action.targetFrame?.isMainFrame ?? true {
                    UIApplication.shared.open(url)
                    return decisionHandler(.cancel)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading() }

        // "Continuar con Facebook" abre una ventana emergente.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = SharedWeb.userAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let controller = UIViewController()
            controller.view = popup
            let nav = UINavigationController(rootViewController: controller)
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
            popupController = nav
            webView.window?.rootViewController?.topMost.present(nav, animated: true)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) { popupController?.dismiss(animated: true) }
    }
}

extension UIViewController {
    var topMost: UIViewController { presentedViewController?.topMost ?? self }
}

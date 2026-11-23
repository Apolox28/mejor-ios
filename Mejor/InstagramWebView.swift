import SwiftUI
import WebKit

/// Todas las pantallas comparten cookies, así que inicias sesión una sola vez.
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

    static func isAppStore(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "apps.apple.com" || host == "itunes.apple.com"
    }

    /// Identidad de Safari para iPhone con la versión real del sistema.
    /// Sin esto Instagram trata la app como un navegador integrado y falla el login.
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

    static func makeConfiguration(section: Section?, handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let controller = WKUserContentController()
        if let section = section {
            controller.addUserScript(WKUserScript(
                source: "window.__merjoSection = '\(section.rawValue)';",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(
                source: FocusFilter.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            controller.addUserScript(WKUserScript(
                source: FocusFilter.loginScript,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.add(WeakScriptHandler(handler), name: "mejor")
        config.userContentController = controller
        return config
    }
}

/// Una página de Instagram con indicador de carga mientras aparece.
struct WebScreen: View {
    let startURL: URL
    let section: Section?
    let resetToken: Int
    var loadDelay: TimeInterval = 0
    var onNavigate: ((URL) -> Void)? = nil

    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            InstagramWebView(startURL: startURL, section: section, resetToken: resetToken,
                             loadDelay: loadDelay, isLoading: $isLoading, onNavigate: onNavigate)
                .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView().scaleEffect(1.2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }
}

struct InstagramWebView: UIViewRepresentable {
    let startURL: URL
    let section: Section?
    let resetToken: Int
    var loadDelay: TimeInterval = 0
    @Binding var isLoading: Bool
    var onNavigate: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: SharedWeb.makeConfiguration(section: section, handler: context.coordinator))
        webView.customUserAgent = SharedWeb.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.keyboardDismissMode = .interactive

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        context.coordinator.webView = webView
        context.coordinator.lastToken = resetToken
        context.coordinator.urlObservation = webView.observe(\.url, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            guard let url = view.url else { return }
            DispatchQueue.main.async {
                coordinator?.applyChrome(for: url.path)
                coordinator?.parent.onNavigate?(url)
            }
        }
        let request = URLRequest(url: startURL)
        if loadDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + loadDelay) { [weak webView] in
                if webView?.url == nil { webView?.load(request) }
            }
        } else {
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            webView.load(URLRequest(url: startURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: InstagramWebView
        weak var webView: WKWebView?
        var lastToken = 0
        var urlObservation: NSKeyValueObservation?
        private weak var popupController: UIViewController?

        init(parent: InstagramWebView) { self.parent = parent }

        /// Mensajes del filtro: cambios de ruta internos y el usuario detectado.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let value = body["value"] as? String else { return }
            switch type {
            case "path":
                if let url = URL(string: "https://www.instagram.com" + value) {
                    applyChrome(for: url.path)
                    parent.onNavigate?(url)
                }
            case "user":
                let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !clean.isEmpty, clean.range(of: "^[A-Za-z0-9._]+$", options: .regularExpression) != nil {
                    UserDefaults.standard.set(clean, forKey: "instagramUser")
                }
            default:
                break
            }
        }

        /// Historias: fondo negro y sin "tirar para recargar", para verlas a pantalla completa.
        func applyChrome(for path: String) {
            guard let webView = webView else { return }
            let story = path.lowercased().hasPrefix("/stories/")
            let color: UIColor = story ? .black : .systemBackground
            webView.backgroundColor = color
            webView.scrollView.backgroundColor = color
            webView.scrollView.bounces = !story
            if story {
                webView.scrollView.refreshControl = nil
            } else if webView.scrollView.refreshControl == nil {
                let refresh = UIRefreshControl()
                refresh.addTarget(self, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
                webView.scrollView.refreshControl = refresh
            }
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
        }

        private func finishLoading() {
            DispatchQueue.main.async {
                if self.parent.isLoading { self.parent.isLoading = false }
            }
        }

        // MARK: Navegación

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""

            if ["about", "blob", "data", "javascript"].contains(scheme) {
                return decisionHandler(.allow)
            }

            // "Abrir en la app" / App Store: se ignoran para no salir de Mejor.
            if SharedWeb.blockedSchemes.contains(scheme) || SharedWeb.isAppStore(url) {
                return decisionHandler(.cancel)
            }

            // Otros sitios (enlaces de una bio, etc.) se abren en Safari.
            if (scheme != "http" && scheme != "https") || !SharedWeb.isAllowed(url) {
                if action.targetFrame?.isMainFrame ?? true {
                    UIApplication.shared.open(url)
                    return decisionHandler(.cancel)
                }
                return decisionHandler(.allow)
            }

            // Secciones bloqueadas en cargas completas de página.
            if parent.section != nil,
               action.targetFrame?.isMainFrame == true,
               let redirect = FocusFilter.redirect(for: url) {
                webView.load(URLRequest(url: redirect))
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            finishLoading()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLoading()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishLoading()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        // MARK: Ventanas emergentes (por ejemplo "Continuar con Facebook")

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url,
               url.scheme == "http" || url.scheme == "https",
               !SharedWeb.isAllowed(url) {
                UIApplication.shared.open(url)
                return nil
            }

            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = SharedWeb.userAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let controller = UIViewController()
            controller.view = popup
            let nav = UINavigationController(rootViewController: controller)
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
            popupController = nav

            webView.window?.rootViewController?.topMost.present(nav, animated: true)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            popupController?.dismiss(animated: true)
        }

        // Diálogos de JavaScript (confirmaciones como "¿Anular envío?").
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(message: message, in: webView, actions: [("OK", true)]) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(message: message, in: webView,
                    actions: [("Cancelar", false), ("Aceptar", true)], completion: completionHandler)
        }

        private func present(message: String, in webView: WKWebView,
                             actions: [(String, Bool)], completion: @escaping (Bool) -> Void) {
            guard let top = webView.window?.rootViewController?.topMost else { return completion(false) }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, value) in actions {
                alert.addAction(UIAlertAction(title: title, style: value ? .default : .cancel) { _ in completion(value) })
            }
            top.present(alert, animated: true)
        }
    }
}

/// Evita que el WKUserContentController retenga al coordinador para siempre.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension UIViewController {
    var topMost: UIViewController {
        presentedViewController?.topMost ?? self
    }
}

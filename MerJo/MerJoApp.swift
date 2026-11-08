import SwiftUI
import WebKit

@main
struct MerJoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(nil)
        }
    }
}

// MARK: - Marca

enum Brand {
    /// Luz del faro.
    static let accent = Color(red: 0.96, green: 0.71, blue: 0.27)
    /// Noche: azul marino profundo.
    static let night = Color(red: 0.016, green: 0.039, blue: 0.118)
    static let backgroundTop = Color(red: 0.027, green: 0.063, blue: 0.176)
    static let background = LinearGradient(colors: [backgroundTop, night],
                                           startPoint: .top, endPoint: .bottom)
    static let ring = LinearGradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.45), accent,
                                              Color(red: 0.91, green: 0.56, blue: 0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Secciones

/// Las únicas tres secciones de la app. No hay feed, ni explorar, ni pestaña de Reels.
enum Section: String, CaseIterable, Identifiable {
    case messages, stories, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return "Mensajes"
        case .stories:  return "Historias"
        case .search:   return "Buscar"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "paperplane"
        case .stories:  return "circle.dashed"
        case .search:   return "magnifyingglass"
        }
    }

    var startURL: URL {
        switch self {
        case .messages: return URL(string: "https://www.instagram.com/direct/inbox/")!
        case .stories:  return URL(string: "https://www.instagram.com/")!
        case .search:   return URL(string: "https://www.instagram.com/explore/search/")!
        }
    }
}

// MARK: - Sesión

/// Sabe si hay una sesión de Instagram mirando la cookie "sessionid".
final class Session: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    enum State { case checking, loggedOut, loggedIn }

    @Published private(set) var state: State = .checking

    private var store: WKHTTPCookieStore { SharedWeb.dataStore.httpCookieStore }

    override init() {
        super.init()
        store.add(self)
        refresh()
    }

    func refresh() {
        store.getAllCookies { [weak self] cookies in
            let hasSession = cookies.contains { cookie in
                cookie.name == "sessionid"
                    && cookie.domain.hasSuffix("instagram.com")
                    && !cookie.value.isEmpty
                    && (cookie.expiresDate ?? .distantFuture) > Date()
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let new: State = hasSession ? .loggedIn : .loggedOut
                if self.state != new { self.state = new }
            }
        }
    }

    /// Se usa cuando la web ya salió del login aunque la cookie tarde en aparecer.
    func markLoggedIn() {
        if state != .loggedIn { state = .loggedIn }
    }

    func signOut() {
        SharedWeb.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                       modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async { self?.state = .loggedOut }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        refresh()
    }
}

// MARK: - Raíz

struct RootView: View {
    @StateObject private var session = Session()

    var body: some View {
        ZStack {
            switch session.state {
            case .checking:  SplashView().transition(.opacity)
            case .loggedOut: WelcomeView().transition(.opacity)
            case .loggedIn:  MainTabs().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.state)
        .environmentObject(session)
    }
}

struct MainTabs: View {
    @State private var selection: Section = .messages
    @State private var resetTokens: [Section: Int] = [:]

    var body: some View {
        TabView(selection: Binding(
            get: { selection },
            set: { new in
                // Tocar la pestaña activa otra vez vuelve a su inicio.
                if new == selection { resetTokens[new, default: 0] += 1 }
                selection = new
            }
        )) {
            ForEach(Section.allCases) { section in
                WebScreen(startURL: section.startURL,
                          section: section,
                          resetToken: resetTokens[section, default: 0])
                    .tabItem { Label(section.title, systemImage: section.icon) }
                    .tag(section)
            }
        }
        .accentColor(Brand.accent)
    }
}

import SwiftUI
import WebKit
import AVFoundation

@main
struct MejorApp: App {
    init() {
        // Las historias con video suenan aunque el iPhone esté en silencio, como en Instagram.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

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

// MARK: - Sesión

/// Sabe si hay una sesión de Instagram mirando la cookie "sessionid".
final class Session: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    enum State { case checking, loggedOut, loggedIn }

    @Published private(set) var state: State = .checking

    private var store: WKHTTPCookieStore { SharedWeb.dataStore.httpCookieStore }

    override init() {
        super.init()
        store.add(self)
        // Instagram rechazó la sesión: se borra y vuelves a la bienvenida para entrar de nuevo.
        InstagramAPI.shared.onLoggedOut = { [weak self] in
            if self?.state == .loggedIn { self?.signOut() }
        }
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
                if !hasSession { UserDefaults.standard.removeObject(forKey: "instagramUser") }
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

/// Barra propia en vez de TabView: todas las pestañas quedan vivas y precargadas,
/// y la barra se puede esconder mientras ves una historia.
/// Pestañas nativas. No existe ninguna pantalla de Reels, Explorar ni feed:
/// la app nunca los pide a Instagram.
struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "circle.dashed.inset.filled") }
            SearchView()
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
            MessagesView()
                .tabItem { Label("Mensajes", systemImage: "paperplane") }
            NavigationView { ProfileView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Perfil", systemImage: "person.crop.circle") }
        }
        .accentColor(Brand.accent)
    }
}

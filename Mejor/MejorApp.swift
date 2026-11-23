import SwiftUI
import AVFoundation

@main
struct MejorApp: App {
    init() {
        // Las historias con video suenan aunque el iPhone esté en silencio, como en Instagram.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup { RootView() }
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

/// Sabe si hay sesión mirando el permiso guardado en el llavero.
final class Session: ObservableObject {
    enum State { case loggedOut, loggedIn }

    @Published private(set) var state: State

    init() {
        state = AuthStore.shared.isLoggedIn ? .loggedIn : .loggedOut
        // Instagram rechazó la sesión: se borra y se vuelve a la bienvenida.
        InstagramAPI.shared.onLoggedOut = { [weak self] in
            guard let self = self, self.state == .loggedIn else { return }
            InstagramAPI.shared.logOut()
            self.state = .loggedOut
        }
    }

    func refresh() {
        let new: State = AuthStore.shared.isLoggedIn ? .loggedIn : .loggedOut
        if state != new { state = new }
    }

    func signOut() {
        InstagramAPI.shared.logOut()
        state = .loggedOut
    }
}

// MARK: - Raíz

struct RootView: View {
    @StateObject private var session = Session()

    var body: some View {
        ZStack {
            switch session.state {
            case .loggedOut: WelcomeView().transition(.opacity)
            case .loggedIn:  MainTabs().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.state)
        .environmentObject(session)
    }
}

/// Pestañas nativas. No existe ninguna pantalla de Reels, Explorar ni feed de Reels:
/// la app nunca los pide a Instagram.
struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
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

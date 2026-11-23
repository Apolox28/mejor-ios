import SwiftUI
import WebKit

@main
struct MejorApp: App {
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

/// Las únicas secciones de la app. No hay feed, ni explorar, ni pestaña de Reels.
enum Section: String, CaseIterable, Identifiable {
    case messages, stories, search, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return "Mensajes"
        case .stories:  return "Historias"
        case .search:   return "Buscar"
        case .profile:  return "Perfil"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "paperplane"
        case .stories:  return "circle.dashed"
        case .search:   return "magnifyingglass"
        case .profile:  return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .messages: return "paperplane.fill"
        case .stories:  return "circle.dashed.inset.filled"
        case .search:   return "magnifyingglass"
        case .profile:  return "person.crop.circle.fill"
        }
    }

    /// El perfil abre el inicio y el filtro salta a /tu_usuario/ en cuanto lo detecta.
    var startURL: URL {
        switch self {
        case .messages: return URL(string: "https://www.instagram.com/direct/inbox/")!
        case .stories:  return URL(string: "https://www.instagram.com/")!
        case .search:   return URL(string: "https://www.instagram.com/explore/search/")!
        case .profile:
            if let user = UserDefaults.standard.string(forKey: "instagramUser"), !user.isEmpty {
                return URL(string: "https://www.instagram.com/\(user)/")!
            }
            return URL(string: "https://www.instagram.com/")!
        }
    }

    /// Mensajes carga primero; el resto se precarga detrás sin competir con él.
    var loadDelay: TimeInterval {
        switch self {
        case .messages: return 0
        case .stories:  return 1.0
        case .search:   return 2.0
        case .profile:  return 2.5
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
struct MainTabs: View {
    @State private var selection: Section = .messages
    @State private var resetTokens: [Section: Int] = [:]
    @State private var paths: [Section: String] = [:]

    /// Una historia abierta en la pestaña visible: pantalla completa.
    private var immersive: Bool {
        (paths[selection] ?? "").hasPrefix("/stories/")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(Section.allCases) { section in
                    WebScreen(startURL: section.startURL,
                              section: section,
                              resetToken: resetTokens[section, default: 0],
                              loadDelay: section.loadDelay) { url in
                        paths[section] = url.path.lowercased()
                    }
                    .opacity(selection == section ? 1 : 0)
                    .allowsHitTesting(selection == section)
                    .accessibilityHidden(selection != section)
                }
            }
            .ignoresSafeArea(edges: immersive ? .all : [])

            if !immersive {
                TabBar(selection: selection) { tapped in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if tapped == selection {
                        // Tocar la pestaña activa otra vez vuelve a su inicio.
                        resetTokens[tapped, default: 0] += 1
                    } else {
                        selection = tapped
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: immersive)
        .animation(.easeInOut(duration: 0.15), value: selection)
        .statusBar(hidden: immersive)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

private struct TabBar: View {
    let selection: Section
    let onTap: (Section) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { section in
                let active = section == selection
                Button {
                    onTap(section)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: active ? section.selectedIcon : section.icon)
                            .font(.system(size: 21, weight: active ? .semibold : .regular))
                            .frame(height: 26)
                        Text(section.title)
                            .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    }
                    .foregroundColor(active ? Brand.accent : Color(.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .background(
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Divider(), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

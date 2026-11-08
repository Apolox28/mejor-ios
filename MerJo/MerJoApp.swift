import SwiftUI

@main
struct MerJoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .accentColor(Color(red: 1.0, green: 0.31, blue: 0.48))
    }
}

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
        .accentColor(Color(red: 1.0, green: 0.31, blue: 0.48))
    }

    var icon: String {
        switch self {
        case .messages: return "paperplane"
        case .stories:  return "circle.dashed"
        case .search:   return "magnifyingglass"
        }
        .accentColor(Color(red: 1.0, green: 0.31, blue: 0.48))
    }

    var startURL: URL {
        switch self {
        case .messages: return URL(string: "https://www.instagram.com/direct/inbox/")!
        case .stories:  return URL(string: "https://www.instagram.com/")!
        case .search:   return URL(string: "https://www.instagram.com/explore/search/")!
        }
        .accentColor(Color(red: 1.0, green: 0.31, blue: 0.48))
    }
}

struct RootView: View {
    @State private var selection: Section = .messages
    @State private var reselect: Section? = nil

    var body: some View {
        TabView(selection: Binding(
            get: { selection },
            set: { new in
                // Tocar la pestaña activa otra vez vuelve a su inicio.
                if new == selection { reselect = new }
                selection = new
            }
        )) {
            ForEach(Section.allCases) { section in
                InstagramWebView(section: section, reselect: $reselect)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .tabItem { Label(section.title, systemImage: section.icon) }
                    .tag(section)
            }
        }
        .accentColor(Color(red: 1.0, green: 0.31, blue: 0.48))
    }
}

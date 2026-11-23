import SwiftUI

// MARK: - Buscador

/// Los resultados aparecen mientras escribes, en el orden de Instagram
/// (las cuentas más parecidas y relevantes primero).
struct SearchView: View {
    @State private var query = ""
    @State private var results: [IGUser] = []
    @State private var error: String?
    @State private var searching = false
    @State private var retry = 0

    var body: some View {
        NavigationView {
            List {
                if let error = error {
                    ErrorBanner(message: error) { retry += 1 }
                        .listRowSeparator(.hidden)
                }
                ForEach(results) { user in
                    NavigationLink(destination: ProfileView(userID: user.id, username: user.username)) {
                        UserRow(user: user)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    Text("Escribe un nombre: los resultados aparecen al instante.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if searching && results.isEmpty {
                    ProgressView()
                } else if !searching && results.isEmpty && error == nil {
                    Text("Sin resultados para «\(query)».").foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Buscar cuentas")
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
            .navigationTitle("Buscar")
            // Cada letra nueva cancela la búsqueda anterior y lanza otra tras una pausa corta.
            .task(id: "\(query)|\(retry)") {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { results = []; error = nil; return }
                searching = true
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let found = try await InstagramAPI.shared.search(text)
                    guard !Task.isCancelled else { return }
                    results = found
                    error = nil
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
                searching = false
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct UserRow: View {
    let user: IGUser
    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: user.profilePicUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.username).font(.system(size: 15, weight: .semibold))
                    if user.isVerified == true {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundColor(.blue)
                    }
                }
                if let name = user.fullName, !name.isEmpty {
                    Text(name).font(.system(size: 14)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Perfil

/// Tu perfil (sin parámetros) o el de otra persona. Solo muestra fotos y carruseles:
/// los videos del perfil son Reels y se omiten.
struct ProfileView: View {
    var userID: String? = nil
    var username: String? = nil
    @EnvironmentObject private var session: Session
    @State private var profile: ProfileDisplay?
    @State private var error: String?
    @State private var opened: ProfileDisplay.Post?
    @State private var showDiagnostics = false

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private var isMine: Bool { userID == nil && username == nil }

    var body: some View {
        ScrollView {
            if let profile = profile {
                header(profile)
                if profile.isPrivate && profile.photoPosts.isEmpty {
                    Label("Esta cuenta es privada", systemImage: "lock")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: grid, spacing: 2) {
                        ForEach(profile.photoPosts) { post in
                            Button { opened = post } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(RemoteImage(url: post.photos.first))
                                    .clipped()
                                    .overlay(alignment: .topTrailing) {
                                        if post.photos.count > 1 {
                                            Image(systemName: "square.on.square.fill")
                                                .font(.system(size: 13))
                                                .foregroundColor(.white)
                                                .shadow(radius: 3)
                                                .padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if let error = error {
                ErrorBanner(message: error) { Task { await load() } }
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle(profile?.username ?? username ?? "Perfil")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isMine {
                    Menu {
                        Button { Task { await load() } } label: {
                            Label("Actualizar", systemImage: "arrow.clockwise")
                        }
                        Button { showDiagnostics = true } label: {
                            Label("Diagnóstico", systemImage: "stethoscope")
                        }
                        Button(role: .destructive) { session.signOut() } label: {
                            Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task { if profile == nil { await load() } }
        .fullScreenCover(item: $opened) { post in PhotoViewer(photos: post.photos) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
    }

    private func header(_ p: ProfileDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Avatar(url: p.picture, size: 88)
                HStack {
                    stat(p.posts, "publicaciones")
                    stat(p.followers, "seguidores")
                    stat(p.following, "seguidos")
                }
            }
            if let name = p.fullName, !name.isEmpty {
                Text(name).font(.system(size: 15, weight: .semibold))
            }
            if let bio = p.biography, !bio.isEmpty {
                Text(bio).font(.system(size: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func stat(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted(.number.notation(.compactName)) } ?? "–")
                .font(.system(size: 17, weight: .bold))
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        do {
            profile = try await InstagramAPI.shared.profile(userID: userID, username: username)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Las fotos de una publicación, deslizables de lado.
struct PhotoViewer: View {
    let photos: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView {
                ForEach(photos, id: \.self) { url in
                    RemoteImage(url: url, contentMode: .fit)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            CloseButton { dismiss() }
        }
        .statusBar(hidden: true)
    }
}

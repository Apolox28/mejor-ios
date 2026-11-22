import SwiftUI

// MARK: - Buscador

struct SearchView: View {
    @State private var query = ""
    @State private var results: [IGUser] = []
    @State private var error: String?

    var body: some View {
        NavigationView {
            List {
                if let error = error {
                    Text(error).foregroundColor(.secondary)
                }
                ForEach(results) { user in
                    NavigationLink(destination: ProfileView(username: user.username)) {
                        UserRow(user: user)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    Text("Busca personas por su nombre de usuario.")
                        .foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Buscar cuentas")
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
            .navigationTitle("Buscar")
            // Espera a que dejes de escribir antes de preguntar a Instagram.
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { results = []; error = nil; return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                do {
                    results = try await InstagramAPI.shared.search(text)
                    error = nil
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
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

/// Tu perfil (username nil) o el de otra persona. Solo muestra fotos: los videos
/// del perfil son Reels y se omiten.
struct ProfileView: View {
    var username: String?
    @EnvironmentObject private var session: Session
    @State private var profile: ProfileUser?
    @State private var error: String?
    @State private var opened: ProfileUser.Node?

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            if let profile = profile {
                header(profile)
                if profile.isPrivate == true && profile.photoPosts.isEmpty {
                    Label("Esta cuenta es privada", systemImage: "lock")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: grid, spacing: 2) {
                        ForEach(profile.photoPosts) { post in
                            Button { opened = post } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(RemoteImage(url: post.thumbnailSrc ?? post.displayUrl))
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
                if username == nil {
                    Menu {
                        Button { Task { await load() } } label: {
                            Label("Actualizar", systemImage: "arrow.clockwise")
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
    }

    private func header(_ p: ProfileUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Avatar(url: p.profilePicUrlHd ?? p.profilePicUrl, size: 88)
                HStack {
                    stat(p.edgeOwnerToTimelineMedia?.count, "publicaciones")
                    stat(p.edgeFollowedBy?.count, "seguidores")
                    stat(p.edgeFollow?.count, "seguidos")
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
            var name = username
            if name == nil, let me = await InstagramAPI.shared.viewerID() {
                name = try await InstagramAPI.shared.userInfo(id: me).username
            }
            guard let name = name else { throw APIError.loggedOut }
            profile = try await InstagramAPI.shared.profile(username: name)
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

import SwiftUI

/// Home como el de Instagram: historias arriba y el feed de quienes sigues debajo,
/// pero solo con fotos y carruseles. Sin Reels, videos, anuncios ni sugerencias.
struct HomeView: View {
    @State private var tray: [TrayReel] = []
    @State private var posts: [IGMedia] = []
    @State private var nextMaxID: String?
    @State private var moreAvailable = true
    @State private var loadingMore = false
    @State private var error: String?
    @State private var viewerID: String?
    @State private var viewer: ViewerStart?
    @State private var seen: Set<String> = []
    @State private var openProfile: String?
    @State private var commentsFor: IGMedia?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            List {
                storiesRow
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                if let error = error, posts.isEmpty {
                    ErrorBanner(message: error) { Task { await reload() } }
                        .listRowSeparator(.hidden)
                }

                ForEach(posts) { post in
                    PostCell(post: post,
                             openProfile: { openProfile = $0 },
                             openComments: { commentsFor = post })
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .onAppear { if post.id == posts.last?.id { Task { await loadMore() } } }
                }

                if loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await reload() }
            .overlay { if posts.isEmpty && tray.isEmpty && error == nil { ProgressView() } }
            .navigationTitle("Mejor")
            .navigationBarTitleDisplayMode(.inline)
            .background(
                NavigationLink(isActive: Binding(get: { openProfile != nil }, set: { if !$0 { openProfile = nil } })) {
                    ProfileView(username: openProfile)
                } label: { EmptyView() }
                .hidden()
            )
        }
        .navigationViewStyle(.stack)
        .task { if posts.isEmpty { await reload() } }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await reloadStories() } } }
        .fullScreenCover(item: $viewer) { start in
            StoryViewer(reels: tray, startIndex: start.id, viewerID: viewerID) { seen.insert($0) }
        }
        .sheet(item: $commentsFor) { CommentsView(post: $0) }
    }

    private var storiesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(tray.enumerated()), id: \.element.id) { index, reel in
                    Button { viewer = ViewerStart(id: index) } label: {
                        VStack(spacing: 6) {
                            Avatar(url: reel.user.profilePicUrl, size: 66,
                                   ring: reel.hasUnseen && !seen.contains(reel.id.value))
                            Text(reel.user.id == viewerID ? "Tu historia" : reel.user.username)
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(width: 76)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .overlay(Divider(), alignment: .bottom)
    }

    private func reload() async {
        viewerID = await InstagramAPI.shared.viewerID()
        async let stories: Void = reloadStories()
        do {
            let page = try await InstagramAPI.shared.timeline(maxID: nil)
            posts = page.posts
            nextMaxID = page.nextMaxId
            moreAvailable = page.moreAvailable ?? (page.nextMaxId != nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await stories
    }

    private func reloadStories() async {
        if let fresh = try? await InstagramAPI.shared.storiesTray() { tray = fresh }
    }

    private func loadMore() async {
        guard moreAvailable, !loadingMore, let maxID = nextMaxID else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await InstagramAPI.shared.timeline(maxID: maxID) else { return }
        let known = Set(posts.map(\.id))
        posts += page.posts.filter { !known.contains($0.id) }
        nextMaxID = page.nextMaxId
        moreAvailable = page.moreAvailable ?? (page.nextMaxId != nil)
    }
}

struct ViewerStart: Identifiable { let id: Int }

// MARK: - Publicación

struct PostCell: View {
    let post: IGMedia
    let openProfile: (String) -> Void
    let openComments: () -> Void

    @State private var liked: Bool
    @State private var likes: Int
    @State private var page = 0
    @State private var burst = false

    init(post: IGMedia, openProfile: @escaping (String) -> Void, openComments: @escaping () -> Void) {
        self.post = post
        self.openProfile = openProfile
        self.openComments = openComments
        _liked = State(initialValue: post.hasLiked == true)
        _likes = State(initialValue: post.likeCount ?? 0)
    }

    private var photos: [IGMedia] { post.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let user = post.user {
                Button { openProfile(user.username) } label: {
                    HStack(spacing: 10) {
                        Avatar(url: user.profilePicUrl, size: 34)
                        Text(user.username).font(.system(size: 14, weight: .semibold))
                        if user.isVerified == true {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundColor(.blue)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            TabView(selection: $page) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                    RemoteImage(url: photo.imageURL).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .aspectRatio(max(0.8, min(photos.first?.aspect ?? 1, 1.91)), contentMode: .fit)
            .clipped()
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: 90))
                    .foregroundColor(.white)
                    .shadow(radius: 8)
                    .scaleEffect(burst ? 1 : 0.4)
                    .opacity(burst ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onTapGesture(count: 2) {
                if !liked { toggleLike() }
                withAnimation(.spring(response: 0.3)) { burst = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation { burst = false } }
            }

            HStack(spacing: 16) {
                Button(action: toggleLike) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundColor(liked ? .red : .primary)
                }
                .accessibilityLabel(liked ? "Quitar me gusta" : "Me gusta")
                Button(action: openComments) { Image(systemName: "bubble.right") }
                    .accessibilityLabel("Comentarios")
                Spacer()
            }
            .font(.system(size: 22))
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                if likes > 0 {
                    Text("\(likes.formatted()) Me gusta").font(.system(size: 14, weight: .semibold))
                }
                if let caption = post.caption?.text, !caption.isEmpty, let user = post.user {
                    (Text(user.username).bold() + Text(" ") + Text(caption))
                        .font(.system(size: 14))
                        .lineLimit(3)
                }
                if let count = post.commentCount, count > 0 {
                    Button(action: openComments) {
                        Text(count == 1 ? "Ver 1 comentario" : "Ver los \(count) comentarios")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let taken = post.takenAt {
                    Text(Date(timeIntervalSince1970: TimeInterval(taken)).shortAgo)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
    }

    private func toggleLike() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        liked.toggle()
        likes += liked ? 1 : -1
        let now = liked
        Task {
            do { try await InstagramAPI.shared.like(post, now) }
            catch { liked = !now; likes += now ? -1 : 1 }
        }
    }
}

// MARK: - Comentarios

struct CommentsView: View {
    let post: IGMedia
    @State private var comments: [IGComment] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    if let error = error { Text(error).foregroundColor(.secondary) }
                    if loaded && comments.isEmpty && error == nil {
                        Text("Todavía no hay comentarios.").foregroundColor(.secondary)
                    }
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(url: comment.user?.profilePicUrl, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                (Text(comment.user?.username ?? "").bold() + Text(" ") + Text(comment.text ?? ""))
                                    .font(.system(size: 14))
                                if let created = comment.createdAt {
                                    Text(Date(timeIntervalSince1970: created).shortAgo)
                                        .font(.system(size: 12)).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.plain)
                .overlay { if !loaded { ProgressView() } }

                HStack(spacing: 10) {
                    TextField("Agrega un comentario…", text: $draft)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button("Publicar", action: send)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Brand.accent)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(.bar)
            }
            .navigationTitle("Comentarios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            comments = try await InstagramAPI.shared.comments(mediaPK: post.mediaPK)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do {
                try await InstagramAPI.shared.addComment(text, mediaPK: post.mediaPK)
                await load()
            } catch {
                self.error = "No se pudo comentar: \(error.localizedDescription)"
                draft = text
            }
        }
    }
}

// MARK: - Visor de historias

/// Historias a pantalla completa: toca a la derecha para avanzar, a la izquierda
/// para volver, desliza hacia abajo para cerrar. En las tuyas ves quién las vio.
struct StoryViewer: View {
    let reels: [TrayReel]
    let viewerID: String?
    let onSeen: (String) -> Void

    @State private var reelIndex: Int
    @State private var itemIndex = 0
    @State private var items: [String: [IGMedia]] = [:]
    @State private var progress: Double = 0
    @State private var dragY: CGFloat = 0
    @State private var activityFor: IGMedia?
    @Environment(\.dismiss) private var dismiss

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(reels: [TrayReel], startIndex: Int, viewerID: String?, onSeen: @escaping (String) -> Void) {
        self.reels = reels
        self.viewerID = viewerID
        self.onSeen = onSeen
        _reelIndex = State(initialValue: startIndex)
    }

    private var reel: TrayReel { reels[reelIndex] }
    private var isMine: Bool { reel.user.id == viewerID }
    private var currentItems: [IGMedia] { items[reel.id.value] ?? [] }
    private var item: IGMedia? { currentItems.indices.contains(itemIndex) ? currentItems[itemIndex] : nil }
    private var duration: Double { item?.videoURL != nil ? (item?.videoDuration ?? 15) : 5 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let item = item {
                Group {
                    if let video = item.videoURL {
                        PlayerView(url: video, onEnd: next)
                    } else {
                        RemoteImage(url: item.imageURL, contentMode: .fit)
                    }
                }
                .id(item.id.value)
                .ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxHeight: .infinity)
            }

            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: previous)
                    .frame(maxWidth: .infinity).accessibilityLabel("Anterior")
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: next)
                    .frame(maxWidth: .infinity).accessibilityLabel("Siguiente")
                    .layoutPriority(1)
            }
            .ignoresSafeArea()

            header

            if isMine, let item = item {
                VStack {
                    Spacer()
                    Button { activityFor = item } label: {
                        Label("Actividad", systemImage: "eye")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .offset(y: dragY)
        .gesture(DragGesture().onChanged { dragY = max(0, $0.translation.height) }
            .onEnded { value in
                if value.translation.height > 120 { dismiss() } else { withAnimation { dragY = 0 } }
            })
        .statusBar(hidden: true)
        .task(id: reel.id.value) { await loadItems() }
        .onChange(of: item?.id.value) { _ in markSeen() }
        .onReceive(tick) { _ in
            guard item != nil, dragY == 0, activityFor == nil else { return }
            progress += 0.05 / duration
            if progress >= 1 { next() }
        }
        .sheet(item: $activityFor) { StoryActivityView(item: $0) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(currentItems.indices, id: \.self) { index in
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white).frame(width: geo.size.width * fill(for: index))
                            }
                    }
                    .frame(height: 2.5)
                }
            }
            HStack(spacing: 10) {
                Avatar(url: reel.user.profilePicUrl, size: 34)
                Text(isMine ? "Tu historia" : reel.user.username).font(.system(size: 15, weight: .semibold))
                if let taken = item?.takenAt {
                    Text(Date(timeIntervalSince1970: TimeInterval(taken)).shortAgo)
                        .font(.system(size: 14)).opacity(0.7)
                }
                Spacer()
                CloseButton { dismiss() }.padding(-12)
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private func fill(for index: Int) -> CGFloat {
        if index < itemIndex { return 1 }
        if index == itemIndex { return CGFloat(min(progress, 1)) }
        return 0
    }

    private func next() {
        progress = 0
        if itemIndex + 1 < currentItems.count {
            itemIndex += 1
        } else if reelIndex + 1 < reels.count {
            reelIndex += 1
            itemIndex = 0
        } else {
            dismiss()
        }
    }

    private func previous() {
        progress = 0
        if itemIndex > 0 {
            itemIndex -= 1
        } else if reelIndex > 0 {
            reelIndex -= 1
            itemIndex = 0
        }
    }

    private func loadItems() async {
        progress = 0
        let key = reel.id.value
        if items[key] == nil {
            let loaded = (try? await InstagramAPI.shared.storyItems(reelID: key)) ?? reel.items ?? []
            if loaded.isEmpty { next(); return }
            items[key] = loaded
        }
        // Precarga al siguiente usuario para que el salto sea instantáneo.
        if reelIndex + 1 < reels.count {
            let nextKey = reels[reelIndex + 1].id.value
            if items[nextKey] == nil, let more = try? await InstagramAPI.shared.storyItems(reelID: nextKey) {
                items[nextKey] = more
            }
        }
    }

    private func markSeen() {
        guard let item = item, !isMine else { return }
        let owner = reel.user.pk.value
        if item.id.value == currentItems.last?.id.value { onSeen(reel.id.value) }
        Task { await InstagramAPI.shared.markSeen(item, ownerID: owner) }
    }
}

/// Quién vio tu historia; el corazón marca a quién le gustó.
struct StoryActivityView: View {
    let item: IGMedia
    @State private var result: ViewersResponse?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let error = error { Text(error).foregroundColor(.secondary) }
                if let result = result {
                    let list = result.list
                    if list.isEmpty { Text("Nadie la ha visto todavía.").foregroundColor(.secondary) }
                    ForEach(list) { entry in
                        HStack {
                            UserRow(user: entry.user)
                            Spacer()
                            if entry.liked {
                                Image(systemName: "heart.fill").foregroundColor(.red)
                                    .accessibilityLabel("Le gustó")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if result == nil && error == nil { ProgressView() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
        .task {
            do { result = try await InstagramAPI.shared.storyViewers(mediaID: item.mediaPK) }
            catch { self.error = error.localizedDescription }
        }
    }

    private var title: String {
        guard let count = result?.totalViewerCount ?? result?.userCount else { return "Actividad" }
        return count == 1 ? "1 visualización" : "\(count) visualizaciones"
    }
}

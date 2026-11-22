import SwiftUI

/// Home: solo las historias de quienes sigues, en grande.
struct HomeView: View {
    @State private var tray: [TrayReel] = []
    @State private var error: String?
    @State private var loading = false
    @State private var viewer: ViewerStart?
    @State private var seen: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]

    var body: some View {
        NavigationView {
            ScrollView {
                if let error = error, tray.isEmpty {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if tray.isEmpty && !loading {
                    Text("No hay historias nuevas.")
                        .foregroundColor(.secondary)
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(Array(tray.enumerated()), id: \.element.id) { index, reel in
                            Button {
                                viewer = ViewerStart(id: index)
                            } label: {
                                VStack(spacing: 10) {
                                    Avatar(url: reel.user.profilePicUrl, size: 124,
                                           ring: reel.hasUnseen && !seen.contains(reel.id.value))
                                    Text(reel.user.username)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .overlay { if loading && tray.isEmpty { ProgressView() } }
            .navigationTitle("Historias")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Actualizar")
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { if tray.isEmpty { await load() } }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await load() } } }
        .fullScreenCover(item: $viewer) { start in
            StoryViewer(reels: tray, startIndex: start.id) { seen.insert($0) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            tray = try await InstagramAPI.shared.storiesTray()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ViewerStart: Identifiable { let id: Int }

/// Visor de historias a pantalla completa: toca a la derecha para avanzar,
/// a la izquierda para volver, desliza hacia abajo para cerrar.
struct StoryViewer: View {
    let reels: [TrayReel]
    let onSeen: (String) -> Void

    @State private var reelIndex: Int
    @State private var itemIndex = 0
    @State private var items: [String: [IGMedia]] = [:]
    @State private var progress: Double = 0
    @State private var dragY: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(reels: [TrayReel], startIndex: Int, onSeen: @escaping (String) -> Void) {
        self.reels = reels
        self.onSeen = onSeen
        _reelIndex = State(initialValue: startIndex)
    }

    private var reel: TrayReel { reels[reelIndex] }
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

            // Zonas de toque: izquierda vuelve, derecha avanza.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: previous)
                    .frame(maxWidth: .infinity).accessibilityLabel("Anterior")
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: next)
                    .frame(maxWidth: .infinity).accessibilityLabel("Siguiente")
                    .layoutPriority(1)
            }
            .ignoresSafeArea()

            header
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
            guard item != nil, dragY == 0 else { return }
            progress += 0.05 / duration
            if progress >= 1 { next() }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(currentItems.indices, id: \.self) { index in
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white)
                                    .frame(width: geo.size.width * fill(for: index))
                            }
                    }
                    .frame(height: 2.5)
                }
            }
            HStack(spacing: 10) {
                Avatar(url: reel.user.profilePicUrl, size: 34)
                Text(reel.user.username).font(.system(size: 15, weight: .semibold))
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
        guard let item = item else { return }
        let owner = reel.user.pk.value
        if item.id.value == currentItems.last?.id.value { onSeen(reel.id.value) }
        Task { await InstagramAPI.shared.markSeen(item, ownerID: owner) }
    }
}

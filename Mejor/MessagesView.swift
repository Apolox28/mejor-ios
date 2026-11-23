import SwiftUI
import AVFoundation

// MARK: - Bandeja

/// Todos tus chats: se cargan de a 20 y siguen llegando al bajar.
struct MessagesView: View {
    @State private var threads: [DMThread] = []
    @State private var cursor: String?
    @State private var hasOlder = false
    @State private var loadingMore = false
    @State private var loaded = false
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            List {
                if let error = error, threads.isEmpty {
                    ErrorBanner(message: error) { Task { await load() } }
                        .listRowSeparator(.hidden)
                }
                ForEach(threads) { thread in
                    NavigationLink(destination: ThreadView(thread: thread)) {
                        ThreadRow(thread: thread)
                    }
                    .onAppear { if thread.id == threads.last?.id { Task { await loadMore() } } }
                }
                if loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay {
                if !loaded { ProgressView() }
                else if threads.isEmpty && error == nil { Text("No tienes chats.").foregroundColor(.secondary) }
            }
            .refreshable { await load() }
            .navigationTitle("Mensajes")
        }
        .navigationViewStyle(.stack)
        .task { await load() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await load() } } }
    }

    private func load() async {
        do {
            let box = try await InstagramAPI.shared.inbox(cursor: nil)
            threads = box.threads
            cursor = box.oldestCursor
            hasOlder = box.hasOlder ?? (box.oldestCursor != nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async {
        guard hasOlder, !loadingMore, let cursor = cursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let box = try? await InstagramAPI.shared.inbox(cursor: cursor) else { return }
        let known = Set(threads.map(\.id))
        threads += box.threads.filter { !known.contains($0.id) }
        self.cursor = box.oldestCursor
        hasOlder = box.hasOlder ?? false
    }
}

private struct ThreadRow: View {
    let thread: DMThread

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: thread.users.first?.profilePicUrl, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let last = thread.items.first {
                    Text("\(last.preview) · \(last.date.shortAgo)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Conversación

struct ThreadView: View {
    let thread: DMThread
    @State private var items: [DMItem]
    @State private var cursor: String?
    @State private var hasOlder: Bool
    @State private var loadingOlder = false
    @State private var viewerID: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var opened: IGMedia?
    @StateObject private var voice = VoicePlayer()

    init(thread: DMThread) {
        self.thread = thread
        _items = State(initialValue: thread.items)
        _cursor = State(initialValue: thread.oldestCursor)
        _hasOlder = State(initialValue: thread.hasOlder ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if hasOlder {
                            Button(loadingOlder ? "Cargando…" : "Ver mensajes anteriores") { Task { await loadOlder() } }
                                .font(.footnote)
                                .disabled(loadingOlder)
                                .padding(.vertical, 6)
                        }
                        // Instagram entrega lo más nuevo primero.
                        ForEach(items.reversed()) { item in
                            MessageBubble(item: item, mine: item.userId?.value == viewerID,
                                          sender: thread.users.first { $0.pk == item.userId },
                                          isGroup: thread.isGroup == true,
                                          voice: voice) { opened = $0 }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: items.first?.id) { newest in
                    if let newest = newest { withAnimation { proxy.scrollTo(newest, anchor: .bottom) } }
                }
                .onAppear { if let newest = items.first?.id { proxy.scrollTo(newest, anchor: .bottom) } }
            }

            if let error = error {
                Text(error).font(.footnote).foregroundColor(.red).padding(.horizontal)
            }

            HStack(spacing: 10) {
                TextField("Mensaje…", text: $draft)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : Brand.accent)
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Enviar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $opened) { MediaViewer(media: $0) }
        .onDisappear { voice.stop() }
        .task {
            viewerID = await InstagramAPI.shared.viewerID()
            // shortcut: se consulta cada 4 s en vez de una conexión en tiempo real.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func refresh() async {
        do {
            let fresh = try await InstagramAPI.shared.thread(id: thread.id)
            let known = Set(fresh.items.map(\.id))
            // Conserva los mensajes antiguos ya cargados.
            items = fresh.items + items.filter { !known.contains($0.id) && $0.date < (fresh.items.last?.date ?? .distantPast) }
            if error?.hasPrefix("No se pudo enviar") != true { error = nil }
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func loadOlder() async {
        guard let cursor = cursor else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let older = try? await InstagramAPI.shared.thread(id: thread.id, cursor: cursor) else { return }
        let known = Set(items.map(\.id))
        items += older.items.filter { !known.contains($0.id) }
        self.cursor = older.oldestCursor
        hasOlder = older.hasOlder ?? false
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            do {
                try await InstagramAPI.shared.send(text: text, threadID: thread.id)
                draft = ""
                error = nil
                await refresh()
            } catch {
                self.error = "No se pudo enviar: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}

private struct MessageBubble: View {
    let item: DMItem
    let mine: Bool
    let sender: IGUser?
    let isGroup: Bool
    @ObservedObject var voice: VoicePlayer
    let open: (IGMedia) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 50) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if isGroup && !mine, let sender = sender {
                    Text(sender.username).font(.system(size: 12)).foregroundColor(.secondary)
                }
                if item.itemType == "reel_share" {
                    Text("Respondió a una historia").font(.system(size: 12)).foregroundColor(.secondary)
                }
                if let media = item.attachment, media.imageURL != nil || media.videoURL != nil {
                    Button { open(media) } label: {
                        RemoteImage(url: media.imageURL)
                            .frame(width: 200, height: 200 / max(0.4, min(media.aspect, 1.5)))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                if media.videoURL != nil {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 42))
                                        .foregroundColor(.white)
                                        .shadow(radius: 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(media.videoURL != nil ? "Ver video" : "Ver foto")
                }
                if let sticker = item.stickerURL {
                    RemoteImage(url: sticker, contentMode: .fit)
                        .frame(maxWidth: 140, maxHeight: 140)
                        .accessibilityLabel("Sticker")
                }
                if let audio = item.voiceURL {
                    Button { voice.toggle(audio) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: voice.playing == audio ? "pause.fill" : "play.fill")
                            Image(systemName: "waveform")
                            if let seconds = item.voiceDuration {
                                Text(String(format: "%d:%02d", Int(seconds / 1000) / 60, Int(seconds / 1000) % 60))
                                    .font(.system(size: 13).monospacedDigit())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(mine ? Brand.accent : Color(.secondarySystemBackground))
                        .foregroundColor(mine ? Brand.night : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mensaje de voz")
                }
                let fallback = (item.attachment == nil && item.stickerURL == nil && item.voiceURL == nil) ? item.preview : nil
                if let text = item.text ?? item.linkText ?? (item.caption?.isEmpty == false ? item.caption : nil) ?? fallback,
                   !text.isEmpty {
                    Text(text)
                        .font(.system(size: 16))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(mine ? Brand.accent : Color(.secondarySystemBackground))
                        .foregroundColor(mine ? Brand.night : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            if !mine { Spacer(minLength: 50) }
        }
    }
}

/// Reproduce un mensaje de voz a la vez.
final class VoicePlayer: ObservableObject {
    @Published private(set) var playing: URL?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        let player = AVPlayer(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in self?.stop() }
        self.player = player
        playing = url
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        playing = nil
    }
}

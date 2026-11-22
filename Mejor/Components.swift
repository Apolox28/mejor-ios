import SwiftUI
import AVFoundation

/// Foto de perfil redonda, con anillo dorado si hay historias sin ver.
struct Avatar: View {
    let url: URL?
    var size: CGFloat = 44
    var ring: Bool = false

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .padding(ring ? max(3, size * 0.05) : 0)
            .overlay(
                Circle().stroke(Brand.ring, lineWidth: ring ? max(2.5, size * 0.04) : 0)
            )
    }
}

/// Imagen remota con fondo neutro mientras carga.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemFill)
            }
        }
    }
}

/// Video sin controles (historias). Avisa cuando termina.
struct PlayerView: UIViewRepresentable {
    let url: URL
    var loop = false
    var onEnd: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView() }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.play(url: url, loop: loop, onEnd: onEnd)
    }

    static func dismantleUIView(_ view: PlayerUIView, coordinator: ()) { view.stop() }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var current: URL?
    private var endObserver: NSObjectProtocol?

    func play(url: URL, loop: Bool, onEnd: (() -> Void)?) {
        guard current != url else { return }
        stop()
        current = url
        let player = AVPlayer(url: url)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak player] _ in
            if loop { player?.seek(to: .zero); player?.play() } else { onEnd?() }
        }
        player.play()
    }

    func stop() {
        playerLayer.player?.pause()
        playerLayer.player = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        current = nil
    }
}

/// Mensaje de error con botón para reintentar.
struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Brand.accent)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Reintentar", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Visor a pantalla completa para una foto o un video recibido.
/// Un solo video: no se puede deslizar a otro (no hay feed de Reels).
struct MediaViewer: View {
    let media: IGMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let video = media.videoURL {
                PlayerView(url: video, loop: true).ignoresSafeArea()
            } else {
                RemoteImage(url: media.imageURL, contentMode: .fit).ignoresSafeArea()
            }
            CloseButton { dismiss() }
        }
        .statusBar(hidden: true)
    }
}

struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
        }
        .padding(12)
        .accessibilityLabel("Cerrar")
    }
}

extension Date {
    /// "ahora", "5 min", "3 h", "2 d".
    var shortAgo: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        switch seconds {
        case ..<60: return "ahora"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86_400: return "\(seconds / 3600) h"
        default: return "\(seconds / 86_400) d"
        }
    }
}

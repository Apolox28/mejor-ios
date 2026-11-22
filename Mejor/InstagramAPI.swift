import Foundation
import UIKit
import WebKit

// Cliente nativo: usa la sesión que dejó el login web (cookies) y las mismas
// llamadas internas que usa instagram.com. Nunca pide Reels, Explorar ni el feed.
// shortcut: son endpoints no documentados; si Instagram los cambia, se ajustan aquí.

enum APIError: LocalizedError {
    case loggedOut
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .loggedOut: return "Tu sesión de Instagram terminó. Vuelve a iniciar sesión."
        case .http(let code): return "Instagram respondió con un error (\(code)). Desliza hacia abajo para reintentar."
        case .message(let text): return text
        }
    }
}

final class InstagramAPI {
    static let shared = InstagramAPI()

    /// Lo conecta Session para volver a la pantalla de bienvenida si la sesión expira.
    var onLoggedOut: (() -> Void)?

    /// Dónde atiende Instagram cada llamada: algunas solo existen en la web y otras
    /// (mensajes, buscador, feed, comentarios) solo en la API de su app de iPhone.
    enum Host {
        case web, app
        var base: String {
            self == .web ? "https://www.instagram.com/api/v1/" : "https://i.instagram.com/api/v1/"
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Identificador fijo de este teléfono para la API de la app.
    private let deviceID: String = {
        if let saved = UserDefaults.standard.string(forKey: "deviceID") { return saved }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "deviceID")
        return new
    }()

    @MainActor
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            SharedWeb.dataStore.httpCookieStore.getAllCookies { all in
                continuation.resume(returning: all.filter { $0.domain.hasSuffix("instagram.com") })
            }
        }
    }

    /// Tu id de usuario, guardado por Instagram en la cookie ds_user_id.
    func viewerID() async -> String? {
        await cookies().first { $0.name == "ds_user_id" }?.value
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], host: Host = .web) async throws -> T {
        var components = URLComponents(string: host.base + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await send(URLRequest(url: components.url!), host: host)
    }

    func post<T: Decodable>(_ path: String, form: [String: String], host: Host = .web) async throws -> T {
        var request = URLRequest(url: URL(string: host.base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(request, host: host)
    }

    private func send<T: Decodable>(_ original: URLRequest, host: Host) async throws -> T {
        var request = original
        let jar = await cookies()
        guard jar.contains(where: { $0.name == "sessionid" }) else {
            await signalLoggedOut()
            throw APIError.loggedOut
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: jar) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(jar.first { $0.name == "csrftoken" }?.value ?? "", forHTTPHeaderField: "X-CSRFToken")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch host {
        case .web:
            request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue(SharedWeb.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        case .app:
            // Se presenta como la app de Instagram para iPhone (las mismas cabeceras que usa Instaloader).
            let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
            request.setValue("Instagram 309.1.0.41.113 (iPhone14,5; iOS \(os); es_CL; es-CL; scale=3.00; 1170x2532; 541635890) AppleWebKit/420+",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("124024574287414", forHTTPHeaderField: "X-IG-App-ID")
            request.setValue("36r/F/8=", forHTTPHeaderField: "X-IG-Capabilities")
            request.setValue("WiFi", forHTTPHeaderField: "X-IG-Connection-Type")
            request.setValue("es-CL", forHTTPHeaderField: "X-IG-App-Locale")
            request.setValue(deviceID, forHTTPHeaderField: "X-IG-Device-ID")
            request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "X-IG-Timezone-Offset")
        }

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if code == 401 || json?["require_login"] as? Bool == true
            || (json?["message"] as? String) == "login_required" {
            await signalLoggedOut()
            throw APIError.loggedOut
        }
        guard (200..<300).contains(code) else {
            if let message = json?["message"] as? String, !message.isEmpty { throw APIError.message(message) }
            throw APIError.http(code)
        }
        return try decoder.decode(T.self, from: data)
    }

    @MainActor private func signalLoggedOut() { onLoggedOut?() }

    // MARK: Historias

    func storiesTray() async throws -> [TrayReel] {
        let tray: ReelsTray = try await get("feed/reels_tray/")
        return tray.tray
    }

    func storyItems(reelID: String) async throws -> [IGMedia] {
        let response: ReelsMedia = try await get("feed/reels_media/", ["reel_ids": reelID])
        if let reel = response.reels?[reelID] { return reel.items ?? [] }
        return response.reelsMedia?.first?.items ?? []
    }

    /// Marca la historia como vista (así apareces en la lista de quien la subió).
    func markSeen(_ item: IGMedia, ownerID: String) async {
        guard let taken = item.takenAt else { return }
        let _: StatusResponse? = try? await post("stories/reel/seen", form: [
            "reelMediaId": item.id.value.components(separatedBy: "_").first ?? item.id.value,
            "reelMediaOwnerId": ownerID,
            "reelId": ownerID,
            "reelMediaTakenAt": String(taken),
            "viewSeenAt": String(Int(Date().timeIntervalSince1970))
        ])
    }

    /// Quién vio una historia tuya (y a quién le gustó).
    func storyViewers(mediaID: String) async throws -> ViewersResponse {
        try await get("media/\(mediaID)/list_reel_media_viewer/", host: .app)
    }

    // MARK: Feed (sin Reels)

    func timeline(maxID: String?) async throws -> FeedPage {
        var form = [
            "reason": maxID == nil ? "cold_start_fetch" : "pagination",
            "is_pull_to_refresh": "0",
            "is_prefetch": "0",
            "feed_view_info": "[]",
            "_uuid": deviceID,
            "device_id": deviceID,
            "phone_id": deviceID,
            "timezone_offset": String(TimeZone.current.secondsFromGMT())
        ]
        if let maxID = maxID { form["max_id"] = maxID }
        return try await post("feed/timeline/", form: form, host: .app)
    }

    func like(_ media: IGMedia, _ liked: Bool) async throws {
        let _: StatusResponse = try await post("web/likes/\(media.mediaPK)/\(liked ? "like" : "unlike")/", form: [:])
    }

    func comments(mediaPK: String) async throws -> [IGComment] {
        let result: CommentsResponse = try await get("media/\(mediaPK)/comments/", ["can_support_threading": "true"], host: .app)
        return result.comments ?? []
    }

    func addComment(_ text: String, mediaPK: String) async throws {
        let _: StatusResponse = try await post("web/comments/\(mediaPK)/add/", form: ["comment_text": text])
    }

    // MARK: Buscador y perfiles

    func search(_ query: String) async throws -> [IGUser] {
        let result: UserSearch = try await get("users/search/", ["q": query, "count": "30"], host: .app)
        return result.users ?? []
    }

    func userInfo(id: String) async throws -> IGUser {
        let info: UserInfo = try await get("users/\(id)/info/", host: .app)
        return info.user
    }

    func profile(username: String) async throws -> ProfileUser {
        let result: WebProfile = try await get("users/web_profile_info/", ["username": username])
        return result.data.user
    }

    // MARK: Mensajes

    func inbox() async throws -> [DMThread] {
        let result: InboxResponse = try await get("direct_v2/inbox/", ["persistentBadging": "true", "limit": "30"], host: .app)
        return result.inbox.threads
    }

    func thread(id: String) async throws -> DMThread {
        let result: ThreadResponse = try await get("direct_v2/threads/\(id)/", ["limit": "40"], host: .app)
        return result.thread
    }

    func send(text: String, threadID: String) async throws {
        let token = UUID().uuidString
        let _: StatusResponse = try await post("direct_v2/threads/broadcast/text/", form: [
            "action": "send_item",
            "thread_ids": "[\(threadID)]",
            "client_context": token,
            "mutation_token": token,
            "_uuid": deviceID,
            "text": text
        ], host: .app)
    }
}

// MARK: - Modelos (todo opcional: Instagram omite campos según el contenido)

/// Ids que Instagram manda a veces como número y a veces como texto.
struct Flex: Decodable, Hashable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else { value = String(try container.decode(Int64.self)) }
    }
    var number: Double { Double(value) ?? 0 }
}

struct StatusResponse: Decodable { let status: String? }

struct Candidate: Decodable { let url: URL; let width: Int?; let height: Int? }
struct ImageVersions: Decodable { let candidates: [Candidate] }

struct IGUser: Decodable, Identifiable, Hashable {
    let pk: Flex
    let username: String
    let fullName: String?
    let profilePicUrl: URL?
    let isVerified: Bool?
    let isPrivate: Bool?
    var id: String { pk.value }

    static func == (a: IGUser, b: IGUser) -> Bool { a.pk == b.pk }
    func hash(into hasher: inout Hasher) { hasher.combine(pk) }
}

struct IGMedia: Decodable, Identifiable {
    let id: Flex
    let mediaType: Int?
    let imageVersions2: ImageVersions?
    let videoVersions: [Candidate]?
    let videoDuration: Double?
    let takenAt: Int?
    let carouselMedia: [IGMedia]?
    let originalWidth: Int?
    let originalHeight: Int?
    // Solo vienen en publicaciones del feed:
    let pk: Flex?
    let productType: String?
    let user: IGUser?
    let caption: Caption?
    let likeCount: Int?
    let commentCount: Int?
    let hasLiked: Bool?
    let injected: Present?

    struct Caption: Decodable { let text: String? }
    /// Marca que solo importa si existe (los anuncios traen "injected").
    struct Present: Decodable {}

    /// El número de la publicación, sin el "_usuario" que trae el id.
    var mediaPK: String { pk?.value ?? id.value.components(separatedBy: "_").first ?? id.value }
    var isVideo: Bool { mediaType == 2 || productType == "clips" || productType == "igtv" }
    /// Fotos de la publicación; los videos de un carrusel se omiten.
    var photos: [IGMedia] {
        if let children = carouselMedia { return children.filter { !$0.isVideo } }
        return isVideo ? [] : [self]
    }

    var imageURL: URL? { imageVersions2?.candidates.first?.url ?? carouselMedia?.first?.imageURL }
    var videoURL: URL? { videoVersions?.first?.url }
    var aspect: CGFloat {
        guard let w = originalWidth, let h = originalHeight, w > 0, h > 0 else { return 9.0 / 16.0 }
        return CGFloat(w) / CGFloat(h)
    }
}

struct FeedPage: Decodable {
    /// Una entrada rara (sugerencias, formatos nuevos) se salta en vez de romper el feed.
    struct Entry: Decodable {
        let mediaOrAd: IGMedia?
        enum CodingKeys: String, CodingKey { case mediaOrAd }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mediaOrAd = try? container.decode(IGMedia.self, forKey: .mediaOrAd)
        }
    }
    let feedItems: [Entry]?
    let nextMaxId: String?
    let moreAvailable: Bool?

    /// Solo publicaciones de fotos de quienes sigues: sin Reels, videos ni anuncios.
    var posts: [IGMedia] {
        (feedItems ?? []).compactMap(\.mediaOrAd).filter { $0.injected == nil && !$0.photos.isEmpty }
    }
}

struct IGComment: Decodable, Identifiable {
    let pk: Flex
    let text: String?
    let user: IGUser?
    let createdAt: Double?
    var id: String { pk.value }
}

struct CommentsResponse: Decodable { let comments: [IGComment]? }

struct ViewersResponse: Decodable {
    struct Viewer: Decodable {
        let user: IGUser?
        let hasLiked: Bool?
    }
    let users: [IGUser]?
    let viewers: [Viewer]?
    let totalViewerCount: Int?
    let userCount: Int?

    struct Entry: Identifiable {
        let user: IGUser
        let liked: Bool
        var id: String { user.id }
    }

    /// Instagram usa una de las dos formas según la versión.
    var list: [Entry] {
        if let viewers = viewers, !viewers.isEmpty {
            return viewers.compactMap { v in v.user.map { Entry(user: $0, liked: v.hasLiked == true) } }
        }
        return (users ?? []).map { Entry(user: $0, liked: false) }
    }
}

struct ReelsTray: Decodable { let tray: [TrayReel] }

/// Una fila de historias de un usuario ("reel" es el nombre interno de Instagram para historias).
struct TrayReel: Decodable, Identifiable {
    let id: Flex
    let user: IGUser
    let seen: Double?
    let latestReelMedia: Double?
    let items: [IGMedia]?

    var hasUnseen: Bool { (seen ?? 0) < (latestReelMedia ?? 0) }
}

struct ReelsMedia: Decodable {
    struct Reel: Decodable { let items: [IGMedia]? }
    let reels: [String: Reel]?
    let reelsMedia: [Reel]?
}

struct UserSearch: Decodable { let users: [IGUser]? }

struct UserInfo: Decodable { let user: IGUser }

struct WebProfile: Decodable {
    struct Payload: Decodable { let user: ProfileUser }
    let data: Payload
}

struct ProfileUser: Decodable {
    struct Count: Decodable { let count: Int }
    struct Timeline: Decodable { let count: Int?; let edges: [Edge]? }
    struct Edge: Decodable { let node: Node }
    struct Children: Decodable { let edges: [Edge]? }
    struct Node: Decodable, Identifiable {
        let id: String
        let displayUrl: URL?
        let thumbnailSrc: URL?
        let isVideo: Bool?
        let edgeSidecarToChildren: Children?
        /// Fotos del post (los videos se omiten: en perfiles casi siempre son Reels).
        var photos: [URL] {
            let children = edgeSidecarToChildren?.edges?.map(\.node).filter { $0.isVideo != true }
                .compactMap(\.displayUrl) ?? []
            return children.isEmpty ? [displayUrl].compactMap { $0 } : children
        }
    }

    let id: String
    let username: String
    let fullName: String?
    let biography: String?
    let profilePicUrlHd: URL?
    let profilePicUrl: URL?
    let isPrivate: Bool?
    let isVerified: Bool?
    let edgeFollowedBy: Count?
    let edgeFollow: Count?
    let edgeOwnerToTimelineMedia: Timeline?

    /// Solo fotos y carruseles: ningún video ni Reel.
    var photoPosts: [Node] {
        (edgeOwnerToTimelineMedia?.edges ?? []).map(\.node).filter { $0.isVideo != true }
    }
}

struct InboxResponse: Decodable {
    struct Box: Decodable { let threads: [DMThread] }
    let inbox: Box
}

struct ThreadResponse: Decodable { let thread: DMThread }

struct DMThread: Decodable, Identifiable {
    let threadId: String
    let threadTitle: String?
    let users: [IGUser]
    let items: [DMItem]?
    let lastActivityAt: Flex?
    let isGroup: Bool?
    var id: String { threadId }

    var title: String {
        if let title = threadTitle, !title.isEmpty { return title }
        return users.map(\.username).joined(separator: ", ")
    }
}

struct DMItem: Decodable, Identifiable {
    struct ClipWrap: Decodable { let clip: IGMedia? }
    struct MediaWrap: Decodable { let media: IGMedia?; let text: String?; let message: String? }
    struct LinkWrap: Decodable { let text: String? }

    let itemId: String
    let userId: Flex?
    let timestamp: Flex?
    let itemType: String?
    let text: String?
    let clip: ClipWrap?
    let mediaShare: IGMedia?
    let media: IGMedia?
    let storyShare: MediaWrap?
    let reelShare: MediaWrap?
    let visualMedia: MediaWrap?
    let link: LinkWrap?
    var id: String { itemId }

    /// Foto o video adjunto, venga de donde venga.
    var attachment: IGMedia? {
        clip?.clip ?? mediaShare ?? media ?? storyShare?.media ?? reelShare?.media ?? visualMedia?.media
    }

    var date: Date { Date(timeIntervalSince1970: (timestamp?.number ?? 0) / 1_000_000) }

    /// Texto para la vista previa de la bandeja.
    var preview: String {
        if let text = text, !text.isEmpty { return text }
        if let text = link?.text, !text.isEmpty { return text }
        switch itemType {
        case "clip", "xma_clip": return "Te envió un reel"
        case "media_share", "xma_media_share": return "Te envió una publicación"
        case "story_share", "xma_story_share", "reel_share": return "Historia"
        case "media", "raven_media", "visual_media": return "Foto o video"
        case "voice_media": return "Mensaje de voz"
        case "like": return "❤️"
        default: return "Mensaje"
        }
    }
}

import Foundation
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

    private let base = "https://www.instagram.com/api/v1/"
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

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await send(URLRequest(url: components.url!))
    }

    func post<T: Decodable>(_ path: String, form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(request)
    }

    private func send<T: Decodable>(_ original: URLRequest) async throws -> T {
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
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(SharedWeb.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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

    // MARK: Llamadas

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

    func search(_ query: String) async throws -> [IGUser] {
        let result: TopSearch = try await get("web/search/topsearch/", ["query": query, "context": "user"])
        return (result.users ?? []).map(\.user)
    }

    func userInfo(id: String) async throws -> IGUser {
        let info: UserInfo = try await get("users/\(id)/info/")
        return info.user
    }

    func profile(username: String) async throws -> ProfileUser {
        let result: WebProfile = try await get("users/web_profile_info/", ["username": username])
        return result.data.user
    }

    func inbox() async throws -> [DMThread] {
        let result: InboxResponse = try await get("direct_v2/inbox/", ["persistentBadging": "true", "limit": "30"])
        return result.inbox.threads
    }

    func thread(id: String) async throws -> DMThread {
        let result: ThreadResponse = try await get("direct_v2/threads/\(id)/", ["limit": "40"])
        return result.thread
    }

    func send(text: String, threadID: String) async throws {
        let token = UUID().uuidString
        let _: StatusResponse = try await post("direct_v2/threads/broadcast/text/", form: [
            "action": "send_item",
            "thread_ids": "[\(threadID)]",
            "client_context": token,
            "mutation_token": token,
            "text": text
        ])
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

    var imageURL: URL? { imageVersions2?.candidates.first?.url ?? carouselMedia?.first?.imageURL }
    var videoURL: URL? { videoVersions?.first?.url }
    var aspect: CGFloat {
        guard let w = originalWidth, let h = originalHeight, w > 0, h > 0 else { return 9.0 / 16.0 }
        return CGFloat(w) / CGFloat(h)
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

struct TopSearch: Decodable {
    struct Hit: Decodable { let user: IGUser }
    let users: [Hit]?
}

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

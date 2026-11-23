import Foundation
import UIKit
import WebKit

// Cliente nativo: usa la sesión que dejó el login web (cookies) y las llamadas
// internas de Instagram. Nunca pide Reels, Explorar ni sugerencias.
// shortcut: son endpoints no documentados; si Instagram los cambia, se ajustan aquí
// (el Diagnóstico muestra qué responde cada uno).

enum APIError: LocalizedError {
    case loggedOut
    case http(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .loggedOut: return "Tu sesión de Instagram terminó. Vuelve a iniciar sesión."
        case .http(let code, let path): return "Instagram respondió con un error (\(code)) en \(path)."
        case .message(let text): return text
        }
    }
}

final class InstagramAPI {
    static let shared = InstagramAPI()

    /// Lo conecta Session para volver a la pantalla de bienvenida si la sesión expira.
    var onLoggedOut: (() -> Void)?

    /// Registro de las últimas respuestas (solo códigos y nombres de campos, nunca contenido).
    @MainActor private(set) var log: [String] = []

    /// Instagram atiende cada llamada en un lugar distinto; se prueban en orden.
    enum Host: String {
        case web   // www.instagram.com como la web
        case app   // i.instagram.com como la app de iPhone
        case iweb  // i.instagram.com con identidad web
        var base: String {
            self == .web ? "https://www.instagram.com/api/v1/" : "https://i.instagram.com/api/v1/"
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
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

    // MARK: Peticiones

    /// `path` puede ser relativo a /api/v1/ o una dirección completa.
    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], host: Host) async throws -> T {
        var components = URLComponents(string: path.hasPrefix("https://") ? path : host.base + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await send(URLRequest(url: components.url!), host: host)
    }

    func post<T: Decodable>(_ path: String, form: [String: String], host: Host) async throws -> T {
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

    /// Prueba cada forma en orden y devuelve la primera que funcione.
    func firstOf<T>(_ attempts: [() async throws -> T]) async throws -> T {
        var lastError: Error = APIError.message("Sin intentos")
        for attempt in attempts {
            do { return try await attempt() } catch APIError.loggedOut { throw APIError.loggedOut } catch { lastError = error }
        }
        throw lastError
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
        if host == .app {
            // Se presenta como la app de Instagram para iPhone (cabeceras como las de Instaloader).
            let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
            request.setValue("Instagram 309.1.0.41.113 (iPhone14,5; iOS \(os); es_CL; es-CL; scale=3.00; 1170x2532; 541635890) AppleWebKit/420+",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("124024574287414", forHTTPHeaderField: "X-IG-App-ID")
            request.setValue("36r/F/8=", forHTTPHeaderField: "X-IG-Capabilities")
            request.setValue("WiFi", forHTTPHeaderField: "X-IG-Connection-Type")
            request.setValue("es-CL", forHTTPHeaderField: "X-IG-App-Locale")
            request.setValue(deviceID, forHTTPHeaderField: "X-IG-Device-ID")
            request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "X-IG-Timezone-Offset")
        } else {
            request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue(SharedWeb.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        }

        let label = "\(request.httpMethod ?? "GET") [\(host.rawValue)] \(request.url?.path ?? "")"
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            await record("\(label) → sin conexión: \(error.localizedDescription)")
            throw error
        }
        let (data, response) = result
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let keys = json.map { $0.keys.sorted().prefix(8).joined(separator: ", ") } ?? "no es JSON"
        let message = (json?["message"] as? String) ?? ""

        if code == 401 || json?["require_login"] as? Bool == true || message == "login_required" {
            await record("\(label) → \(code) sesión rechazada")
            await signalLoggedOut()
            throw APIError.loggedOut
        }
        guard (200..<300).contains(code) else {
            await record("\(label) → \(code) \(message.isEmpty ? keys : message)")
            if !message.isEmpty { throw APIError.message("\(message) (\(code))") }
            throw APIError.http(code, request.url?.path ?? "")
        }
        do {
            let value = try decoder.decode(T.self, from: data)
            await record("\(label) → \(code) ok · \(keys)")
            return value
        } catch let error as DecodingError {
            let detail = Self.describe(error)
            await record("\(label) → \(code) formato distinto: \(detail) · campos: \(keys)")
            throw APIError.message("Instagram respondió en un formato distinto (\(detail)).")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "falta «\(key.stringValue)» en \(path(context))"
        case .typeMismatch(_, let context): return "tipo distinto en \(path(context))"
        case .valueNotFound(_, let context): return "valor vacío en \(path(context))"
        case .dataCorrupted(let context): return "datos dañados en \(path(context))"
        @unknown default: return "error de formato"
        }
    }

    @MainActor private func record(_ line: String) {
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    @MainActor private func signalLoggedOut() { onLoggedOut?() }

    // MARK: Historias

    func storiesTray() async throws -> [TrayReel] {
        let tray: ReelsTray = try await firstOf([
            { try await self.get("feed/reels_tray/", host: .web) },
            { try await self.get("feed/reels_tray/", host: .app) }
        ])
        return tray.tray
    }

    func storyItems(reelID: String) async throws -> [IGMedia] {
        try await firstOf([
            { try await self.reelsMedia(reelID, host: .web) },
            { try await self.reelsMedia(reelID, host: .app) },
            {
                let story: UserStory = try await self.get("feed/user/\(reelID)/story/", host: .app)
                guard let items = story.reel?.items, !items.isEmpty else { throw APIError.message("Sin historias") }
                return items
            }
        ])
    }

    private func reelsMedia(_ reelID: String, host: Host) async throws -> [IGMedia] {
        let response: ReelsMedia = try await get("feed/reels_media/", ["reel_ids": reelID], host: host)
        let items = response.reels?[reelID]?.value?.items ?? response.reelsMedia?.first?.value?.items ?? []
        if items.isEmpty { throw APIError.message("La historia llegó vacía") }
        return items
    }

    /// Marca la historia como vista (así apareces en la lista de quien la subió).
    func markSeen(_ item: IGMedia, ownerID: String) async {
        guard let taken = item.takenAt else { return }
        let _: StatusResponse? = try? await post("stories/reel/seen", form: [
            "reelMediaId": item.mediaPK,
            "reelMediaOwnerId": ownerID,
            "reelId": ownerID,
            "reelMediaTakenAt": String(taken),
            "viewSeenAt": String(Int(Date().timeIntervalSince1970))
        ], host: .web)
    }

    /// Quién vio una historia tuya (y a quién le gustó).
    func storyViewers(mediaID: String) async throws -> ViewersResponse {
        try await firstOf([
            { try await self.get("media/\(mediaID)/list_reel_media_viewer/", host: .app) },
            { try await self.get("media/\(mediaID)/list_reel_media_viewer/", host: .iweb) }
        ])
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
        return try await firstOf([
            { try await self.post("feed/timeline/", form: form, host: .app) },
            { try await self.post("feed/timeline/", form: form, host: .iweb) }
        ])
    }

    func like(_ media: IGMedia, _ liked: Bool) async throws {
        let _: StatusResponse = try await post("web/likes/\(media.mediaPK)/\(liked ? "like" : "unlike")/", form: [:], host: .web)
    }

    func comments(mediaPK: String) async throws -> [IGComment] {
        let result: CommentsResponse = try await firstOf([
            { try await self.get("media/\(mediaPK)/comments/", ["can_support_threading": "true"], host: .app) },
            { try await self.get("media/\(mediaPK)/comments/", ["can_support_threading": "true"], host: .web) }
        ])
        return result.comments?.compactMap(\.value) ?? []
    }

    func addComment(_ text: String, mediaPK: String) async throws {
        let _: StatusResponse = try await post("web/comments/\(mediaPK)/add/", form: ["comment_text": text], host: .web)
    }

    // MARK: Buscador

    /// Cuentas que se parecen a lo escrito, en el orden de Instagram (las más relevantes primero).
    func search(_ query: String) async throws -> [IGUser] {
        try await firstOf([
            {
                let r: TopSearch = try await self.get("https://www.instagram.com/web/search/topsearch/",
                                                      ["query": query, "context": "blended"], host: .web)
                return r.users?.compactMap { $0.value?.user } ?? []
            },
            {
                let r: TopSearch = try await self.get("web/search/topsearch/", ["query": query], host: .web)
                return r.users?.compactMap { $0.value?.user } ?? []
            },
            {
                let r: UserSearch = try await self.get("users/search/", ["q": query, "count": "30"], host: .app)
                return r.users?.compactMap(\.value) ?? []
            },
            {
                let r: FlatSearch = try await self.get("fbsearch/topsearch_flat/", ["query": query, "context": "user"], host: .app)
                return r.list?.compactMap { $0.value?.user } ?? []
            }
        ])
    }

    // MARK: Perfiles

    func userInfo(id: String) async throws -> IGUser {
        let info: UserInfo = try await firstOf([
            { try await self.get("users/\(id)/info/", host: .app) },
            { try await self.get("users/\(id)/info/", host: .iweb) }
        ])
        guard let user = info.user else { throw APIError.message("Instagram no devolvió el perfil.") }
        return user
    }

    func userPosts(id: String) async throws -> [IGMedia] {
        let page: UserFeed = try await firstOf([
            { try await self.get("feed/user/\(id)/", ["count": "33"], host: .app) },
            { try await self.get("feed/user/\(id)/", ["count": "33"], host: .iweb) }
        ])
        return page.items?.compactMap(\.value) ?? []
    }

    /// Perfil completo. Primero por id (API de la app); si falla, por nombre (web).
    func profile(userID: String?, username: String?) async throws -> ProfileDisplay {
        var id = userID
        if id == nil && username == nil { id = await viewerID() }
        var firstError: Error?
        if let id = id {
            do {
                let user = try await userInfo(id: id)
                let posts = (try? await userPosts(id: id)) ?? []
                return ProfileDisplay(user: user, posts: posts)
            } catch APIError.loggedOut {
                throw APIError.loggedOut
            } catch {
                firstError = error
            }
        }
        guard let name = username else { throw firstError ?? APIError.loggedOut }
        let web: WebProfile = try await get("users/web_profile_info/", ["username": name], host: .web)
        guard let user = web.data?.user else { throw firstError ?? APIError.message("Perfil no disponible.") }
        return ProfileDisplay(web: user)
    }

    // MARK: Mensajes

    func inbox(cursor: String?) async throws -> InboxResponse.Box {
        var query = ["persistentBadging": "true", "limit": "20", "thread_message_limit": "10"]
        if let cursor = cursor { query["cursor"] = cursor }
        let result: InboxResponse = try await firstOf([
            { try await self.get("direct_v2/inbox/", query, host: .app) },
            { try await self.get("direct_v2/inbox/", query, host: .iweb) },
            { try await self.get("direct_v2/inbox/", query, host: .web) }
        ])
        guard let box = result.inbox else { throw APIError.message("Instagram no devolvió la bandeja.") }
        return box
    }

    func thread(id: String, cursor: String? = nil) async throws -> DMThread {
        var query = ["limit": "50"]
        if let cursor = cursor { query["cursor"] = cursor }
        let result: ThreadResponse = try await firstOf([
            { try await self.get("direct_v2/threads/\(id)/", query, host: .app) },
            { try await self.get("direct_v2/threads/\(id)/", query, host: .iweb) }
        ])
        guard let thread = result.thread else { throw APIError.message("Instagram no devolvió el chat.") }
        return thread
    }

    func send(text: String, threadID: String) async throws {
        let token = UUID().uuidString
        let form = [
            "action": "send_item",
            "thread_ids": "[\(threadID)]",
            "client_context": token,
            "mutation_token": token,
            "_uuid": deviceID,
            "text": text
        ]
        let _: StatusResponse = try await firstOf([
            { try await self.post("direct_v2/threads/broadcast/text/", form: form, host: .app) },
            { try await self.post("direct_v2/threads/broadcast/text/", form: form, host: .iweb) }
        ])
    }

    /// Prueba cada parte de la app y deja el resultado en el registro.
    func runDiagnostics() async {
        let me = await viewerID()
        await record("— Diagnóstico · sesión \(me == nil ? "sin id" : "con id") —")
        _ = try? await storiesTray()
        _ = try? await timeline(maxID: nil)
        _ = try? await search("a")
        _ = try? await inbox(cursor: nil)
        if let me = me {
            _ = try? await userInfo(id: me)
            _ = try? await userPosts(id: me)
        }
    }
}

// MARK: - Modelos
// Todo es tolerante: si Instagram omite o cambia un campo, se ignora ese dato
// en vez de romper la pantalla completa.

/// Decodifica un elemento y, si falla, lo deja en nil en vez de romper la lista.
struct Safe<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
    func softList<T: Decodable>(_ key: Key) -> [T]? { (soft(key) as [Safe<T>]?)?.compactMap(\.value) }
}

/// Ids que Instagram manda a veces como número y a veces como texto.
struct Flex: Decodable, Hashable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let number = try? container.decode(Int64.self) { value = String(number) }
        else { value = String(try container.decode(Double.self)) }
    }
    var number: Double { Double(value) ?? 0 }
}

struct StatusResponse: Decodable { let status: String? }

struct Candidate: Decodable { let url: URL; let width: Int?; let height: Int? }
struct ImageVersions: Decodable { let candidates: [Safe<Candidate>]?
    var first: URL? { candidates?.compactMap(\.value).first?.url }
}

struct IGUser: Decodable, Identifiable, Hashable {
    let pk: Flex
    let username: String
    let fullName: String?
    let profilePicUrl: URL?
    let isVerified: Bool?
    let isPrivate: Bool?
    let biography: String?
    let followerCount: Int?
    let followingCount: Int?
    let mediaCount: Int?
    let hdProfilePicUrlInfo: Candidate?
    var id: String { pk.value }

    enum CodingKeys: String, CodingKey {
        case pk, id, username, fullName, profilePicUrl, isVerified, isPrivate, biography
        case followerCount, followingCount, mediaCount, hdProfilePicUrlInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pk = c.soft(.pk) ?? c.soft(.id) ?? Flex("0")
        username = c.soft(.username) ?? ""
        fullName = c.soft(.fullName)
        profilePicUrl = c.soft(.profilePicUrl)
        isVerified = c.soft(.isVerified)
        isPrivate = c.soft(.isPrivate)
        biography = c.soft(.biography)
        followerCount = c.soft(.followerCount)
        followingCount = c.soft(.followingCount)
        mediaCount = c.soft(.mediaCount)
        hdProfilePicUrlInfo = c.soft(.hdProfilePicUrlInfo)
    }

    static func == (a: IGUser, b: IGUser) -> Bool { a.pk == b.pk }
    func hash(into hasher: inout Hasher) { hasher.combine(pk) }
}

struct IGMedia: Decodable, Identifiable {
    let id: Flex
    let pk: Flex?
    let mediaType: Int?
    let productType: String?
    let imageVersions2: ImageVersions?
    let videoVersions: [Candidate]?
    let videoDuration: Double?
    let takenAt: Int?
    let carouselMedia: [IGMedia]?
    let originalWidth: Int?
    let originalHeight: Int?
    let user: IGUser?
    let caption: Caption?
    let likeCount: Int?
    let commentCount: Int?
    let hasLiked: Bool?
    let isAd: Bool
    let song: String?

    struct Caption: Decodable { let text: String? }
    /// Sticker de música de una historia: título y artista de la canción.
    struct MusicSticker: Decodable {
        struct Asset: Decodable { let title: String?; let displayArtist: String? }
        let musicAssetInfo: Asset?
    }

    enum CodingKeys: String, CodingKey {
        case id, pk, mediaType, productType, imageVersions2, videoVersions, videoDuration, takenAt
        case carouselMedia, originalWidth, originalHeight, user, caption, likeCount, commentCount
        case hasLiked, injected, storyMusicStickers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pk: Flex? = c.soft(.pk)
        self.pk = pk
        id = c.soft(.id) ?? pk ?? Flex(UUID().uuidString)
        mediaType = c.soft(.mediaType)
        productType = c.soft(.productType)
        imageVersions2 = c.soft(.imageVersions2)
        videoVersions = c.softList(.videoVersions)
        videoDuration = c.soft(.videoDuration)
        takenAt = c.soft(.takenAt)
        carouselMedia = c.softList(.carouselMedia)
        originalWidth = c.soft(.originalWidth)
        originalHeight = c.soft(.originalHeight)
        user = c.soft(.user)
        caption = c.soft(.caption)
        likeCount = c.soft(.likeCount)
        commentCount = c.soft(.commentCount)
        hasLiked = c.soft(.hasLiked)
        isAd = c.contains(.injected)
        let sticker = (c.softList(.storyMusicStickers) as [MusicSticker]?)?.first?.musicAssetInfo
        if let title = sticker?.title, !title.isEmpty {
            song = [title, sticker?.displayArtist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            song = nil
        }
    }

    /// El número de la publicación, sin el "_usuario" que trae el id.
    var mediaPK: String { pk?.value ?? id.value.components(separatedBy: "_").first ?? id.value }
    var isVideo: Bool { mediaType == 2 || productType == "clips" || productType == "igtv" }
    /// Fotos de la publicación; los videos de un carrusel se omiten.
    var photos: [IGMedia] {
        if let children = carouselMedia, !children.isEmpty { return children.filter { !$0.isVideo } }
        return isVideo ? [] : [self]
    }

    var imageURL: URL? { imageVersions2?.first ?? carouselMedia?.first?.imageURL }
    var videoURL: URL? { videoVersions?.first?.url }
    var aspect: CGFloat {
        guard let w = originalWidth, let h = originalHeight, w > 0, h > 0 else { return 9.0 / 16.0 }
        return CGFloat(w) / CGFloat(h)
    }
}

struct FeedPage: Decodable {
    struct Entry: Decodable { let mediaOrAd: IGMedia? }
    let feedItems: [Safe<Entry>]?
    let nextMaxId: String?
    let moreAvailable: Bool?

    /// Solo publicaciones de fotos de quienes sigues: sin Reels, videos ni anuncios.
    var posts: [IGMedia] {
        (feedItems ?? []).compactMap { $0.value?.mediaOrAd }.filter { !$0.isAd && !$0.photos.isEmpty }
    }
}

struct IGComment: Decodable, Identifiable {
    let pk: Flex
    let text: String?
    let user: IGUser?
    let createdAt: Double?
    var id: String { pk.value }
}

struct CommentsResponse: Decodable { let comments: [Safe<IGComment>]? }

struct ViewersResponse: Decodable {
    struct Viewer: Decodable { let user: IGUser?; let hasLiked: Bool? }
    let users: [Safe<IGUser>]?
    let viewers: [Safe<Viewer>]?
    let totalViewerCount: Int?
    let userCount: Int?

    struct Entry: Identifiable {
        let user: IGUser
        let liked: Bool
        var id: String { user.id }
    }

    /// Instagram usa una de las dos formas según la versión.
    var list: [Entry] {
        let fromViewers = (viewers ?? []).compactMap(\.value).compactMap { v in
            v.user.map { Entry(user: $0, liked: v.hasLiked == true) }
        }
        if !fromViewers.isEmpty { return fromViewers }
        return (users ?? []).compactMap(\.value).map { Entry(user: $0, liked: false) }
    }
}

struct ReelsTray: Decodable {
    let trayItems: [Safe<TrayReel>]?
    enum CodingKeys: String, CodingKey { case tray }
    init(from decoder: Decoder) throws {
        trayItems = try decoder.container(keyedBy: CodingKeys.self).soft(.tray)
    }
    var tray: [TrayReel] { (trayItems ?? []).compactMap(\.value).filter { !$0.user.username.isEmpty } }
}

/// Una fila de historias de un usuario ("reel" es el nombre interno de Instagram para historias).
struct TrayReel: Decodable, Identifiable {
    let id: Flex
    let user: IGUser
    let seen: Double?
    let latestReelMedia: Double?
    let items: [IGMedia]?

    enum CodingKeys: String, CodingKey { case id, user, seen, latestReelMedia, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(IGUser.self, forKey: .user)
        id = c.soft(.id) ?? user.pk
        seen = c.soft(.seen)
        latestReelMedia = c.soft(.latestReelMedia)
        items = c.softList(.items)
    }

    var hasUnseen: Bool { (seen ?? 0) < (latestReelMedia ?? 0) }
}

struct ReelsMedia: Decodable {
    struct Reel: Decodable {
        let items: [IGMedia]?
        enum CodingKeys: String, CodingKey { case items }
        init(from decoder: Decoder) throws { items = try decoder.container(keyedBy: CodingKeys.self).softList(.items) }
    }
    let reels: [String: Safe<Reel>]?
    let reelsMedia: [Safe<Reel>]?
}

struct UserStory: Decodable { let reel: ReelsMedia.Reel? }

struct TopSearch: Decodable {
    struct Hit: Decodable { let user: IGUser }
    let users: [Safe<Hit>]?
}

struct FlatSearch: Decodable {
    struct Hit: Decodable { let user: IGUser? }
    let list: [Safe<Hit>]?
}

struct UserSearch: Decodable { let users: [Safe<IGUser>]? }

struct UserInfo: Decodable { let user: IGUser? }

struct UserFeed: Decodable { let items: [Safe<IGMedia>]? }

struct WebProfile: Decodable {
    struct Payload: Decodable { let user: ProfileUser? }
    let data: Payload?
}

/// Formato de perfil de la web (solo se usa como respaldo).
struct ProfileUser: Decodable {
    struct Count: Decodable { let count: Int? }
    struct Timeline: Decodable { let count: Int?; let edges: [Safe<Edge>]? }
    struct Edge: Decodable { let node: Node }
    struct Children: Decodable { let edges: [Safe<Edge>]? }
    struct Node: Decodable {
        let displayUrl: URL?
        let isVideo: Bool?
        let edgeSidecarToChildren: Children?
        var photos: [URL] {
            let children = (edgeSidecarToChildren?.edges ?? []).compactMap { $0.value?.node }
                .filter { $0.isVideo != true }.compactMap(\.displayUrl)
            return children.isEmpty ? [displayUrl].compactMap { $0 } : children
        }
    }

    let username: String?
    let fullName: String?
    let biography: String?
    let profilePicUrlHd: URL?
    let profilePicUrl: URL?
    let isPrivate: Bool?
    let edgeFollowedBy: Count?
    let edgeFollow: Count?
    let edgeOwnerToTimelineMedia: Timeline?
}

/// Lo que muestra la pantalla de perfil, venga de la app o de la web.
struct ProfileDisplay {
    struct Post: Identifiable {
        let id = UUID()
        let photos: [URL]
    }

    let username: String
    let fullName: String?
    let biography: String?
    let picture: URL?
    let posts: Int?
    let followers: Int?
    let following: Int?
    let isPrivate: Bool
    /// Solo fotos y carruseles: ningún video ni Reel.
    let photoPosts: [Post]

    init(user: IGUser, posts media: [IGMedia]) {
        username = user.username
        fullName = user.fullName
        biography = user.biography
        picture = user.hdProfilePicUrlInfo?.url ?? user.profilePicUrl
        posts = user.mediaCount
        followers = user.followerCount
        following = user.followingCount
        isPrivate = user.isPrivate == true
        photoPosts = media.map { Post(photos: $0.photos.compactMap(\.imageURL)) }.filter { !$0.photos.isEmpty }
    }

    init(web: ProfileUser) {
        username = web.username ?? ""
        fullName = web.fullName
        biography = web.biography
        picture = web.profilePicUrlHd ?? web.profilePicUrl
        posts = web.edgeOwnerToTimelineMedia?.count
        followers = web.edgeFollowedBy?.count
        following = web.edgeFollow?.count
        isPrivate = web.isPrivate == true
        photoPosts = (web.edgeOwnerToTimelineMedia?.edges ?? []).compactMap { $0.value?.node }
            .filter { $0.isVideo != true }.map { Post(photos: $0.photos) }.filter { !$0.photos.isEmpty }
    }
}

struct InboxResponse: Decodable {
    struct Box: Decodable {
        let threadList: [Safe<DMThread>]?
        let oldestCursor: String?
        let hasOlder: Bool?
        enum CodingKeys: String, CodingKey { case threads, oldestCursor, hasOlder }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            threadList = c.soft(.threads)
            oldestCursor = c.soft(.oldestCursor)
            hasOlder = c.soft(.hasOlder)
        }
        var threads: [DMThread] { (threadList ?? []).compactMap(\.value) }
    }
    let inbox: Box?
}

struct ThreadResponse: Decodable { let thread: DMThread? }

struct DMThread: Decodable, Identifiable {
    let threadId: String
    let threadTitle: String?
    let users: [IGUser]
    let items: [DMItem]
    let isGroup: Bool?
    let oldestCursor: String?
    let hasOlder: Bool?
    var id: String { threadId }

    enum CodingKeys: String, CodingKey { case threadId, threadTitle, users, items, isGroup, oldestCursor, hasOlder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(Flex.self, forKey: .threadId).value
        threadTitle = c.soft(.threadTitle)
        users = c.softList(.users) ?? []
        items = c.softList(.items) ?? []
        isGroup = c.soft(.isGroup)
        oldestCursor = c.soft(.oldestCursor)
        hasOlder = c.soft(.hasOlder)
    }

    var title: String {
        if let title = threadTitle, !title.isEmpty { return title }
        let names = users.map(\.username).filter { !$0.isEmpty }
        return names.isEmpty ? "Chat" : names.joined(separator: ", ")
    }
}

struct DMItem: Decodable, Identifiable {
    struct MediaWrap: Decodable { let media: IGMedia?; let text: String? }
    struct ClipWrap: Decodable { let clip: IGMedia? }
    struct LinkWrap: Decodable { let text: String? }
    struct Animated: Decodable {
        struct Images: Decodable { struct Size: Decodable { let url: URL? }; let fixedHeight: Size? }
        let images: Images?
    }
    struct Voice: Decodable { struct Media: Decodable { struct Audio: Decodable { let audioSrc: URL?; let duration: Double? }; let audio: Audio? }; let media: Media? }

    let itemId: String
    let userId: Flex?
    let timestamp: Flex?
    let itemType: String?
    let text: String?
    let attachment: IGMedia?
    let stickerURL: URL?
    let voiceURL: URL?
    let voiceDuration: Double?
    let linkText: String?
    let caption: String?
    var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId, userId, timestamp, itemType, text, clip, mediaShare, media, storyShare, reelShare
        case visualMedia, link, animatedMedia, voiceMedia
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = (c.soft(.itemId) as Flex?)?.value ?? UUID().uuidString
        userId = c.soft(.userId)
        timestamp = c.soft(.timestamp)
        itemType = c.soft(.itemType)
        text = c.soft(.text)
        let story: MediaWrap? = c.soft(.storyShare)
        let reel: MediaWrap? = c.soft(.reelShare)
        let visual: MediaWrap? = c.soft(.visualMedia)
        attachment = (c.soft(.clip) as ClipWrap?)?.clip ?? c.soft(.mediaShare) ?? c.soft(.media)
            ?? story?.media ?? reel?.media ?? visual?.media
        caption = reel?.text ?? story?.text
        stickerURL = (c.soft(.animatedMedia) as Animated?)?.images?.fixedHeight?.url
        let voice: Voice? = c.soft(.voiceMedia)
        voiceURL = voice?.media?.audio?.audioSrc
        voiceDuration = voice?.media?.audio?.duration
        linkText = (c.soft(.link) as LinkWrap?)?.text
    }

    var date: Date { Date(timeIntervalSince1970: (timestamp?.number ?? 0) / 1_000_000) }

    /// Texto para la vista previa de la bandeja.
    var preview: String {
        if let text = text, !text.isEmpty { return text }
        if let text = linkText, !text.isEmpty { return text }
        switch itemType {
        case "clip", "xma_clip": return "Te envió un reel"
        case "media_share", "xma_media_share": return "Te envió una publicación"
        case "story_share", "xma_story_share": return "Compartió una historia"
        case "reel_share": return "Respondió a una historia"
        case "media", "raven_media", "visual_media": return "Foto o video"
        case "animated_media": return "Sticker"
        case "voice_media": return "Mensaje de voz"
        case "like": return "❤️"
        case "action_log": return "Actividad"
        default: return "Mensaje"
        }
    }
}

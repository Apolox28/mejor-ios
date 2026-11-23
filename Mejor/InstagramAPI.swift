import Foundation
import UIKit

// Cliente nativo del propio usuario: inicia sesión con su cuenta y consulta
// Instagram con una sola identidad de principio a fin (como instagrapi).
// Nunca pide Reels, Explorar ni sugerencias.
// shortcut: endpoints no documentados; si Instagram los cambia, se ajustan aquí
// (el Diagnóstico muestra qué responde cada uno).

enum APIError: LocalizedError {
    case loggedOut
    case message(String)

    var errorDescription: String? {
        switch self {
        case .loggedOut: return "Tu sesión de Instagram terminó. Vuelve a iniciar sesión."
        case .message(let text): return text
        }
    }
}

/// Lo que pide Instagram después de la contraseña.
enum LoginStep: Equatable {
    case done
    case twoFactor(identifier: String, hint: String)
    case checkpoint(path: String, hint: String)
}

final class InstagramAPI {
    static let shared = InstagramAPI()

    /// Lo conecta Session para volver a la bienvenida si la sesión expira.
    var onLoggedOut: (() -> Void)?

    /// Registro de respuestas (solo códigos y nombres de campos, nunca contenido).
    @MainActor private(set) var log: [String] = []

    private let auth = AuthStore.shared
    private let appVersion = "449.0.0.52.84"
    private let versionCode = "1079242191"
    private let bloksVersion = "799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b"
    private let appID = "567067343352427"

    private var userAgent: String {
        "Instagram \(appVersion) Android (34/14; 480dpi; 1344x2992; Google/google; Pixel 8 Pro; husky; husky; es_CL; \(versionCode))"
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func viewerID() async -> String? { auth.userID }

    // MARK: Petición base

    private struct Raw {
        let code: Int
        let data: Data
        let json: [String: Any]
        let headers: [AnyHashable: Any]
        var status: String { json["status"] as? String ?? "" }
        var message: String { json["message"] as? String ?? "" }
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name.lowercased() }?.value as? String
        }
    }

    /// `path` relativo a /api/v1/ o dirección completa. `form` != nil hace un POST;
    /// `signed` lo manda como signed_body, igual que la app oficial.
    private func raw(_ path: String, query: [String: String] = [:],
                     form: [String: String]? = nil, signed: Bool = true,
                     authed: Bool = true) async throws -> Raw {
        var components = URLComponents(string: path.hasPrefix("https://") ? path : "https://i.instagram.com/api/v1/" + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)

        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(appID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(bloksVersion, forHTTPHeaderField: "X-Bloks-Version-Id")
        request.setValue("3brTv10=", forHTTPHeaderField: "X-IG-Capabilities")
        request.setValue("WIFI", forHTTPHeaderField: "X-IG-Connection-Type")
        request.setValue("es_CL", forHTTPHeaderField: "X-IG-App-Locale")
        request.setValue("es_CL", forHTTPHeaderField: "X-IG-Device-Locale")
        request.setValue("CL", forHTTPHeaderField: "X-IG-App-Startup-Country")
        request.setValue(auth.uuid, forHTTPHeaderField: "X-IG-Device-ID")
        request.setValue(auth.phoneID, forHTTPHeaderField: "X-IG-Family-Device-ID")
        request.setValue(auth.androidID, forHTTPHeaderField: "X-IG-Android-ID")
        request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "X-IG-Timezone-Offset")
        request.setValue(auth.pigeonSession, forHTTPHeaderField: "X-Pigeon-Session-Id")
        request.setValue("0", forHTTPHeaderField: "X-IG-WWW-Claim")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let mid = auth.mid { request.setValue(mid, forHTTPHeaderField: "X-MID") }
        if authed, let authorization = auth.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            if let id = auth.userID {
                request.setValue(id, forHTTPHeaderField: "IG-U-DS-USER-ID")
                request.setValue(id, forHTTPHeaderField: "IG-INTENDED-USER-ID")
            }
        }

        if let form = form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.encodeForm(form, signed: signed)
        }

        let label = "\(request.httpMethod ?? "GET") \(components.path)"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            await record("\(label) → sin conexión")
            throw error
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let result = Raw(code: code, data: data, json: json, headers: http?.allHeaderFields ?? [:])

        if let mid = result.header("ig-set-x-mid") { auth.mid = mid }
        if result.message == "login_required" || result.json["require_login"] as? Bool == true {
            await record("\(label) → sesión rechazada")
            await signalLoggedOut()
            throw APIError.loggedOut
        }
        return result
    }

    private static func encodeForm(_ form: [String: String], signed: Bool) -> Data {
        func encode(_ pairs: [String: String]) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return pairs.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&")
        }
        if signed {
            let json = (try? JSONSerialization.data(withJSONObject: form)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            // La app oficial firma el cuerpo; hoy basta el prefijo "SIGNATURE." sin firma.
            return encode(["signed_body": "SIGNATURE.\(json)"]).data(using: .utf8) ?? Data()
        }
        return encode(form).data(using: .utf8) ?? Data()
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let result = try await raw(path, query: query)
        return try await decode(T.self, from: result, label: "GET " + shortPath(path))
    }

    /// Decodifica, y si el formato cambió deja el motivo en el registro.
    private func decode<T: Decodable>(_ type: T.Type, from result: Raw, label: String) async throws -> T {
        guard (200..<300).contains(result.code) else {
            await record("\(label) → \(result.code) \(result.message.isEmpty ? fields(result.json) : result.message)")
            throw APIError.message(result.message.isEmpty ? "Instagram respondió con un error (\(result.code))." : result.message)
        }
        do {
            let value = try decoder.decode(T.self, from: result.data)
            await record("\(label) → ok · \(fields(result.json))")
            return value
        } catch let error as DecodingError {
            await record("\(label) → formato distinto: \(Self.describe(error))")
            throw APIError.message("Instagram respondió en un formato distinto (\(Self.describe(error))).")
        }
    }

    private func fields(_ json: [String: Any]) -> String { json.keys.sorted().prefix(8).joined(separator: ", ") }
    private func shortPath(_ path: String) -> String { path.hasPrefix("https://") ? (URL(string: path)?.path ?? path) : path }
    private func record(_ line: String) async { await MainActor.run { appendLog(line) } }
    @MainActor private func appendLog(_ line: String) { log.append(line); if log.count > 80 { log.removeFirst(log.count - 80) } }
    @MainActor private func signalLoggedOut() { onLoggedOut?() }

    // MARK: Inicio de sesión

    /// Paso 1: usuario y contraseña. Devuelve qué falta (2FA, código, o listo).
    func logIn(username: String, password: String) async throws -> LoginStep {
        _ = try? await raw("accounts/contact_point_prefill/", form: ["phone_id": auth.phoneID, "usage": "prefill"], signed: false, authed: false)
        let (keyID, publicKey) = try await encryptionKey()
        let encrypted = try PasswordCrypto.encrypt(password, keyID: keyID, publicKeyBase64: publicKey)
        let form = [
            "jazoest": jazoest(auth.phoneID),
            "country_codes": "[{\"country_code\":\"56\",\"source\":[\"default\"]}]",
            "phone_id": auth.phoneID,
            "enc_password": encrypted,
            "username": username,
            "adid": auth.adID,
            "guid": auth.uuid,
            "device_id": auth.androidID,
            "google_tokens": "[]",
            "login_attempt_count": "0"
        ]
        auth.username = username
        let result = try await raw("accounts/login/", form: form, authed: false)
        return try await finishLogin(result)
    }

    /// Paso 2a: el código de la app de autenticación o del SMS.
    func submitTwoFactor(code: String, identifier: String, username: String) async throws -> LoginStep {
        let form = [
            "verification_code": code.trimmingCharacters(in: .whitespaces),
            "phone_id": auth.phoneID,
            "two_factor_identifier": identifier,
            "username": username,
            "trust_this_device": "1",
            "guid": auth.uuid,
            "device_id": auth.androidID,
            "waterfall_id": UUID().uuidString,
            "verification_method": "3"
        ]
        let result = try await raw("accounts/two_factor_login/", form: form, authed: false)
        return try await finishLogin(result)
    }

    /// Paso 2b: pide a Instagram que envíe el código por correo.
    func requestEmailCode(challengePath: String) async throws {
        let path = challengePath.hasPrefix("/") ? String(challengePath.dropFirst()) : challengePath
        _ = try? await raw(path, query: ["guid": auth.uuid, "device_id": auth.androidID], authed: false)
        _ = try await raw(path, form: ["choice": "1", "guid": auth.uuid, "device_id": auth.androidID], signed: false, authed: false)
    }

    /// Paso 2b (cont.): el código que llegó por correo.
    func submitEmailCode(_ code: String, challengePath: String) async throws -> LoginStep {
        let path = challengePath.hasPrefix("/") ? String(challengePath.dropFirst()) : challengePath
        let form = ["security_code": code.trimmingCharacters(in: .whitespaces),
                    "guid": auth.uuid, "device_id": auth.androidID]
        let result = try await raw(path, form: form, signed: false, authed: false)
        return try await finishLogin(result)
    }

    /// Guarda el permiso cuando el inicio de sesión queda completo.
    private func finishLogin(_ result: Raw) async throws -> LoginStep {
        if let authorization = result.header("ig-set-authorization"), !authorization.isEmpty {
            auth.authorization = authorization.hasPrefix("Bearer") ? authorization : "Bearer \(authorization)"
        }
        if let user = result.json["logged_in_user"] as? [String: Any] {
            auth.userID = idString(user["pk"])
            if let name = user["username"] as? String { auth.username = name }
            await record("login → ok como \(auth.username ?? "?")")
            return .done
        }
        // Tras 2FA o el código por correo, Instagram a veces solo entrega el permiso.
        // Si ya tenemos el permiso, confirmamos quién eres con una llamada aparte.
        if auth.authorization != nil, result.status == "ok" || result.json["action"] as? String == "close" {
            if let me = try? await currentUser() {
                auth.userID = idString(me["pk"])
                if let name = me["username"] as? String { auth.username = name }
                await record("login → ok (confirmado) como \(auth.username ?? "?")")
                return .done
            }
        }
        if result.json["two_factor_required"] as? Bool == true,
           let info = result.json["two_factor_info"] as? [String: Any],
           let identifier = info["two_factor_identifier"] as? String {
            let hint = (info["obfuscated_phone_number"] as? String).map { "Código enviado a \($0)" } ?? "Escribe el código de verificación"
            return .twoFactor(identifier: identifier, hint: hint)
        }
        if let challenge = result.json["challenge"] as? [String: Any], let path = challenge["api_path"] as? String {
            return .checkpoint(path: path, hint: "Instagram necesita verificar que eres tú.")
        }
        let message = result.message.isEmpty ? "No se pudo iniciar sesión. Revisa tu usuario y contraseña." : result.message
        throw APIError.message(message)
    }

    /// Confirma la sesión y devuelve tus datos de usuario (pk, username).
    private func currentUser() async throws -> [String: Any]? {
        let result = try await raw("accounts/current_user/", query: ["edit": "false"])
        return result.json["user"] as? [String: Any]
    }

    /// Pide la clave pública con la que se cifra la contraseña (viene en las cabeceras).
    private func encryptionKey() async throws -> (Int, String) {
        let result = try await raw("launcher/sync/",
                                   form: ["id": auth.uuid, "server_config_retrieval": "1"], authed: false)
        guard let idText = result.header("ig-set-password-encryption-key-id"), let id = Int(idText),
              let key = result.header("ig-set-password-encryption-pub-key") else {
            throw APIError.message("Instagram no entregó la clave de cifrado. Intenta de nuevo.")
        }
        return (id, key)
    }

    private func jazoest(_ symbols: String) -> String { "2\(symbols.unicodeScalars.reduce(0) { $0 + Int($1.value) })" }
    private func idString(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func logOut() { auth.clear() }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let c): return "falta «\(key.stringValue)» en \(path(c))"
        case .typeMismatch(_, let c): return "tipo distinto en \(path(c))"
        case .valueNotFound(_, let c): return "valor vacío en \(path(c))"
        case .dataCorrupted(let c): return "datos dañados en \(path(c))"
        @unknown default: return "error de formato"
        }
    }

    // MARK: Historias

    func storiesTray() async throws -> [TrayReel] {
        let form = ["supported_capabilities_new": "[]", "reason": "cold_start",
                    "timezone_offset": String(TimeZone.current.secondsFromGMT()),
                    "page_size": "50", "_uuid": auth.uuid]
        let result = try await raw("feed/reels_tray/", form: form)
        let tray = try await decode(ReelsTray.self, from: result, label: "GET feed/reels_tray/")
        return tray.tray
    }

    func storyItems(reelID: String) async throws -> [IGMedia] {
        let story: UserStory = try await get("feed/user/\(reelID)/story/")
        if let items = story.reel?.items, !items.isEmpty { return items }
        let response: ReelsMedia = try await get("feed/reels_media/", ["reel_ids": reelID])
        let items = response.reels?[reelID]?.value?.items ?? response.reelsMedia?.first?.value?.items ?? []
        if items.isEmpty { throw APIError.message("La historia llegó vacía.") }
        return items
    }

    func markSeen(_ item: IGMedia, ownerID: String) async {
        guard let taken = item.takenAt else { return }
        _ = try? await raw("story/reel/seen", form: [
            "container_module": "feed_timeline",
            "live_vods": "[]",
            "reel_media_skipped": "[]",
            "reels": "{\"\(ownerID)_\(ownerID)\":[\"\(item.mediaPK)_\(ownerID)|\(taken)\"]}",
            "reel_media_viewed": String(Int(Date().timeIntervalSince1970)),
            "_uuid": auth.uuid
        ])
    }

    func storyViewers(mediaID: String) async throws -> ViewersResponse {
        try await get("media/\(mediaID)/list_reel_media_viewer/")
    }

    // MARK: Feed (sin Reels)

    func timeline(maxID: String?) async throws -> FeedPage {
        var form = [
            "reason": maxID == nil ? "cold_start_fetch" : "pagination",
            "is_pull_to_refresh": "0",
            "feed_view_info": "[]",
            "timezone_offset": String(TimeZone.current.secondsFromGMT()),
            "_uuid": auth.uuid
        ]
        if let maxID = maxID { form["max_id"] = maxID }
        let result = try await raw("feed/timeline/", form: form)
        return try await decode(FeedPage.self, from: result, label: "GET feed/timeline/")
    }

    func like(_ media: IGMedia, _ liked: Bool) async throws {
        _ = try await raw("media/\(media.mediaPK)/\(liked ? "like" : "unlike")/",
                         form: ["media_id": media.mediaPK, "_uuid": auth.uuid])
    }

    func comments(mediaPK: String) async throws -> [IGComment] {
        let result: CommentsResponse = try await get("media/\(mediaPK)/comments/", ["can_support_threading": "true"])
        return result.comments?.compactMap(\.value) ?? []
    }

    func addComment(_ text: String, mediaPK: String) async throws {
        _ = try await raw("media/\(mediaPK)/comment/", form: ["comment_text": text, "_uuid": auth.uuid])
    }

    // MARK: Buscador

    func search(_ query: String) async throws -> [IGUser] {
        let result: UserSearch = try await get("users/search/", ["q": query, "count": "30",
                                                                 "timezone_offset": String(TimeZone.current.secondsFromGMT())])
        return result.users?.compactMap(\.value) ?? []
    }

    // MARK: Perfiles

    func userInfo(id: String) async throws -> IGUser {
        let info: UserInfo = try await get("users/\(id)/info/")
        guard let user = info.user else { throw APIError.message("Instagram no devolvió el perfil.") }
        return user
    }

    func userPosts(id: String) async throws -> [IGMedia] {
        let page: UserFeed = try await get("feed/user/\(id)/", ["count": "33"])
        return page.items?.compactMap(\.value) ?? []
    }

    func profile(userID: String?, username: String?) async throws -> ProfileDisplay {
        var id = userID
        if id == nil, username == nil { id = auth.userID }
        if id == nil, let name = username {
            id = try? await search(name).first { $0.username.lowercased() == name.lowercased() }?.id
        }
        guard let id = id else { throw APIError.message("No se encontró el perfil.") }
        let user = try await userInfo(id: id)
        let posts = (try? await userPosts(id: id)) ?? []
        return ProfileDisplay(user: user, posts: posts)
    }

    // MARK: Mensajes

    func inbox(cursor: String?) async throws -> InboxResponse.Box {
        var query = ["visual_message_return_type": "unseen", "persistentBadging": "true",
                     "limit": "20", "thread_message_limit": "10"]
        if let cursor = cursor { query["cursor"] = cursor }
        let result: InboxResponse = try await get("direct_v2/inbox/", query)
        guard let box = result.inbox else { throw APIError.message("Instagram no devolvió la bandeja.") }
        return box
    }

    func thread(id: String, cursor: String? = nil) async throws -> DMThread {
        var query = ["limit": "50", "visual_message_return_type": "unseen"]
        if let cursor = cursor { query["cursor"] = cursor }
        let result: ThreadResponse = try await get("direct_v2/threads/\(id)/", query)
        guard let thread = result.thread else { throw APIError.message("Instagram no devolvió el chat.") }
        return thread
    }

    func send(text: String, threadID: String) async throws {
        let token = String(Int(Date().timeIntervalSince1970 * 1000)) + String(Int.random(in: 100...999))
        _ = try await raw("direct_v2/threads/broadcast/text/", form: [
            "action": "send_item",
            "thread_ids": "[\(threadID)]",
            "client_context": token,
            "mutation_token": token,
            "_uuid": auth.uuid,
            "device_id": auth.androidID,
            "text": text
        ], signed: false)
    }

    func runDiagnostics() async {
        await record("— Diagnóstico · sesión \(auth.isLoggedIn ? "activa como \(auth.username ?? "?")" : "cerrada") —")
        _ = try? await storiesTray()
        _ = try? await timeline(maxID: nil)
        _ = try? await search("a")
        _ = try? await inbox(cursor: nil)
        if let me = auth.userID {
            _ = try? await userInfo(id: me)
            _ = try? await userPosts(id: me)
        }
    }
}

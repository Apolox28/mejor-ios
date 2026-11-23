import Foundation
import UIKit

// Modelos tolerantes: si Instagram omite o cambia un campo, se ignora ese dato
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

struct Candidate: Decodable { let url: URL; let width: Int?; let height: Int? }
struct ImageVersions: Decodable {
    let candidates: [Safe<Candidate>]?
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

/// Una fila de historias de un usuario ("reel" es el nombre interno de Instagram).
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

struct UserSearch: Decodable { let users: [Safe<IGUser>]? }

struct UserInfo: Decodable { let user: IGUser? }

struct UserFeed: Decodable { let items: [Safe<IGMedia>]? }

/// Lo que muestra la pantalla de perfil.
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
        threadId = (c.soft(.threadId) as Flex?)?.value ?? ""
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
    struct Voice: Decodable {
        struct Media: Decodable { struct Audio: Decodable { let audioSrc: URL?; let duration: Double? }; let audio: Audio? }
        let media: Media?
    }

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

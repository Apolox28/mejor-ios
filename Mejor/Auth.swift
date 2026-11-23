import Foundation
import Security
import CryptoKit

// MARK: - Llavero

/// Guarda el permiso de Instagram en el llavero del iPhone (nunca la contraseña).
enum Keychain {
    private static let service = "com.apolox28.mejor"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value = value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Identidad del dispositivo y sesión

/// Lo que Instagram usa para reconocer este teléfono y tu sesión.
final class AuthStore {
    static let shared = AuthStore()

    private let defaults = UserDefaults.standard

    /// Identificadores fijos de este teléfono (se crean una vez).
    let uuid: String
    let phoneID: String
    let androidID: String
    let adID: String
    let pigeonSession = "UFS-\(UUID().uuidString.lowercased())-0"

    private init() {
        func stable(_ key: String, _ make: () -> String) -> String {
            if let saved = UserDefaults.standard.string(forKey: key) { return saved }
            let value = make()
            UserDefaults.standard.set(value, forKey: key)
            return value
        }
        uuid = stable("ig.uuid") { UUID().uuidString.lowercased() }
        phoneID = stable("ig.phoneID") { UUID().uuidString.lowercased() }
        adID = stable("ig.adID") { UUID().uuidString.lowercased() }
        androidID = stable("ig.androidID") {
            "android-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        }
    }

    /// "Bearer IGT:2:…" que entrega Instagram al iniciar sesión.
    var authorization: String? {
        get { Keychain.get("authorization") }
        set { Keychain.set("authorization", newValue) }
    }
    var userID: String? {
        get { Keychain.get("userID") }
        set { Keychain.set("userID", newValue) }
    }
    var username: String? {
        get { defaults.string(forKey: "ig.username") }
        set { defaults.set(newValue, forKey: "ig.username") }
    }
    var mid: String? {
        get { defaults.string(forKey: "ig.mid") }
        set { defaults.set(newValue, forKey: "ig.mid") }
    }

    var isLoggedIn: Bool { authorization != nil && userID != nil }

    func clear() {
        authorization = nil
        userID = nil
    }
}

// MARK: - Cifrado de la contraseña

/// Cifra la contraseña como la app oficial antes de enviarla: AES-256-GCM con una
/// clave al azar, y esa clave cifrada con la clave pública RSA que entrega Instagram.
enum PasswordCrypto {
    static func encrypt(_ password: String, keyID: Int, publicKeyBase64: String) throws -> String {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let rsaKey = try publicKey(fromBase64PEM: publicKeyBase64)

        let sessionKey = SymmetricKey(size: .bits256)
        let sessionKeyData = sessionKey.withUnsafeBytes { Data($0) }
        var error: Unmanaged<CFError>?
        guard let rsaEncrypted = SecKeyCreateEncryptedData(rsaKey, .rsaEncryptionPKCS1,
                                                          sessionKeyData as CFData, &error) as Data? else {
            throw APIError.message("No se pudo cifrar la contraseña.")
        }

        let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let sealed = try AES.GCM.seal(Data(password.utf8), using: sessionKey,
                                      nonce: AES.GCM.Nonce(data: iv),
                                      authenticating: Data(timestamp.utf8))

        var payload = Data([1, UInt8(truncatingIfNeeded: keyID)])
        payload.append(iv)
        let size = UInt16(rsaEncrypted.count)
        payload.append(contentsOf: [UInt8(size & 0xff), UInt8(size >> 8)])  // little endian
        payload.append(rsaEncrypted)
        payload.append(sealed.tag)
        payload.append(sealed.ciphertext)
        return "#PWD_INSTAGRAM:4:\(timestamp):\(payload.base64EncodedString())"
    }

    /// Instagram entrega un PEM en base64; iOS necesita la clave RSA "desnuda" (PKCS#1).
    private static func publicKey(fromBase64PEM base64: String) throws -> SecKey {
        guard let pemData = Data(base64Encoded: base64), let pem = String(data: pemData, encoding: .utf8) else {
            throw APIError.message("Instagram envió una clave de cifrado inválida.")
        }
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else {
            throw APIError.message("Instagram envió una clave de cifrado inválida.")
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        for candidate in [stripSPKIHeader(der), der].compactMap({ $0 }) {
            if let key = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, nil) { return key }
        }
        throw APIError.message("No se pudo leer la clave de cifrado de Instagram.")
    }

    /// Quita la envoltura X.509 (SubjectPublicKeyInfo) y deja la clave PKCS#1.
    static func stripSPKIHeader(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index]); index += 1
            if first < 0x80 { return first }
            let count = first & 0x7f
            guard count <= 4, index + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            return length
        }
        // SEQUENCE { SEQUENCE algoritmo, BIT STRING { 0x00, clave PKCS#1 } }
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard readLength() != nil, index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithmLength = readLength() else { return nil }
        index += algorithmLength
        guard index < bytes.count, bytes[index] == 0x03 else { return nil }
        index += 1
        guard readLength() != nil, index < bytes.count else { return nil }
        index += 1  // bits sin usar
        return index < bytes.count ? Data(bytes[index...]) : nil
    }
}

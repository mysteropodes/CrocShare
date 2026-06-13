import Foundation
import Security

/// Stockage des secrets de contact dans le trousseau macOS,
/// plutôt qu'en clair dans contacts.json.
enum Keychain {
    static let service = "com.crocshare.app.secrets"

    static func set(_ secret: String, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(secret.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Seed d'identité P2P (§4)
    // La seed du compagnon P2P ne touche jamais le disque en clair : Swift la
    // garde au Trousseau et la transmet au Core via la requête `init`.

    static let identityService = "com.mysteropode.crocshare.identity"
    private static let identityAccount = "core-seed"

    static func getIdentitySeed() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identityService,
            kSecAttrAccount as String: identityAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setIdentitySeed(_ seed: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identityService,
            kSecAttrAccount as String: identityAccount,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(seed.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(seed.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

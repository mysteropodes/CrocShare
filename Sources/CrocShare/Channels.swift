import Foundation
import CryptoKit

/// Dérivation déterministe des codes croc à partir du secret partagé.
/// Les deux machines calculent les mêmes codes sans jamais se reparler des clés :
/// c'est ce qui rend la gestion des clés automatique après l'appairage initial.
enum Channels {
    static func code(secret: String, label: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "cs-" + String(hex.prefix(24))
    }

    /// Canal sur lequel `from` publie sa liste de fichiers à destination de `to`.
    static func manifest(secret: String, from: UUID, to: UUID) -> String {
        code(secret: secret, label: "manifest:\(from.uuidString):\(to.uuidString)")
    }

    /// Canal sur lequel `from` envoie ses demandes de téléchargement à `to`.
    static func request(secret: String, from: UUID, to: UUID) -> String {
        code(secret: secret, label: "request:\(from.uuidString):\(to.uuidString)")
    }

    /// Canal éphémère de livraison des fichiers pour une requête donnée.
    static func files(secret: String, requestID: String) -> String {
        code(secret: secret, label: "files:\(requestID)")
    }

    /// Code d'appairage à usage unique, lisible par un humain.
    static func newPairingCode() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let part = { String((0..<4).map { _ in chars.randomElement()! }) }
        return "share-\(part())-\(part())-\(part())"
    }

    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

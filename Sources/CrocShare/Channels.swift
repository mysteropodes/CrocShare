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
        // ⚠️ Un seul bloc, sans tiret ni préfixe commun : croc utilise le premier
        // segment du code (avant le premier tiret) comme identifiant de SALLE sur
        // le relai. Un préfixe commun type "cs-" fait collisionner tous les canaux
        // de tous les utilisateurs dans la même salle ("room full", PAKE failed).
        return String(hex.prefix(26))
    }

    /// Canal sur lequel `from` publie sa liste de fichiers à destination de `to`.
    static func manifest(secret: String, from: UUID, to: UUID) -> String {
        code(secret: secret, label: "manifest:\(from.uuidString):\(to.uuidString)")
    }

    /// Canal sur lequel `from` envoie ses demandes de téléchargement à `to`.
    static func request(secret: String, from: UUID, to: UUID) -> String {
        code(secret: secret, label: "request:\(from.uuidString):\(to.uuidString)")
    }

    /// Canal chat dédié (réactif) : `from` envoie ses messages à `to`.
    static func chat(secret: String, from: UUID, to: UUID) -> String {
        code(secret: secret, label: "chat:\(from.uuidString):\(to.uuidString)")
    }

    /// Canal éphémère de livraison des fichiers pour une requête donnée.
    static func files(secret: String, requestID: String) -> String {
        code(secret: secret, label: "files:\(requestID)")
    }

    /// Code d'appairage à usage unique, lisible par un humain.
    /// Un seul bloc sans tiret (même raison : la salle relai = premier segment).
    static func newPairingCode() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }

    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

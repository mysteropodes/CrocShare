import Foundation
import CryptoKit

// Intégration KDriveRelay ↔ P2PEngine
//
// Le moteur P2P expose deux choses au module relai :
//   • Une clé symétrique par paire (déterministe, dérivée des pubkeys).
//   • Un point d'entrée pour réinjecter les messages livrés par le relai dans
//     le pipeline `handlePayload` existant — comme s'ils étaient arrivés en
//     direct via Hyperswarm.
//
// Note sécurité : la clé est dérivée de la concaténation triée des deux
// pubkeys. C'est suffisant pour empêcher un opérateur kDrive de lire les
// payloads (il faudrait connaître les pubkeys ET y appliquer le HKDF), mais
// PAS résistant à un attaquant qui connaît déjà les deux pubkeys (publiques
// par définition). Pour une version production, négocier un secret aléatoire
// pendant le pairing P2P et le stocker en Trousseau (TODO).

extension P2PEngine: RelayPairKeyProvider {

    public func shortKey(for fullKey: String) -> String {
        String(fullKey.prefix(8))
    }

    public func relayKey(for contactKey: String) -> SymmetricKey? {
        guard !myPublicKey.isEmpty, !contactKey.isEmpty else { return nil }
        let sorted = [myPublicKey, contactKey].sorted().joined(separator: ":")
        return RelayCrypto.derive(sharedSecret: Data(sorted.utf8),
                                  contextTag: "crocshare-relay-v1")
    }

    public var contactsForRelay: [String] { contacts }

    /// À appeler une fois au démarrage. Idempotent.
    func bootRelay(config: KDriveRelayConfig) {
        Task {
            await KDriveRelay.shared.configure(config, keyProvider: self)
            await KDriveRelay.shared.setOnMessageReceived { [weak self] sender, _, payload in
                guard let self else { return }
                guard let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
                Task { @MainActor in
                    // Réinjecte dans le pipeline standard : `handlePayload` gère
                    // dédup par id, ack côté pair, notification, etc.
                    self.injectFromRelay(payload: dict, sender: sender)
                }
            }
            // Purge des fichiers trop vieux : si un destinataire ne s'est jamais
            // reconnecté, on libère l'espace au bout de N jours.
            try? await KDriveRelay.shared.cleanupOldMessages()
        }
    }

    /// Entrée explicite pour les messages venant du relai. Comme `handlePayload`
    /// est `private`, on passe par une bascule équivalente qui ajoute au chat.
    /// Si on l'expose un jour publiquement, remplacer par un appel direct.
    @MainActor
    func injectFromRelay(payload: [String: Any], sender contactKey: String) {
        // On ne traite que les types nécessaires en mode asynchrone. Les
        // accusés/réactions/manifestes circulent en direct quand les deux
        // pairs sont en ligne.
        switch payload["k"] as? String {
        case "msg":
            guard let idStr = payload["id"] as? String, let id = UUID(uuidString: idStr) else { return }
            let text = payload["t"] as? String ?? ""
            let date = (payload["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let ch = (payload["ch"] as? String).flatMap { UUID(uuidString: $0) }
            let rt = (payload["rt"] as? String).flatMap { UUID(uuidString: $0) }
            var att: P2PAttachment?
            if let a = payload["att"] as? [String: Any], let fn = a["fileName"] as? String,
               let rp = a["relPath"] as? String {
                let sz = (a["size"] as? NSNumber)?.int64Value ?? Int64(a["size"] as? Int ?? 0)
                att = P2PAttachment(fileName: fn, relPath: rp, size: sz)
            }
            var thread = chats[contactKey] ?? []
            guard !thread.contains(where: { $0.id == id }) else { return }
            thread.append(P2PMessage(id: id, fromMe: false, fromName: name(for: contactKey),
                                     text: text, date: date, delivered: true,
                                     channel: ch, attachment: att, fromKey: contactKey, replyTo: rt))
            thread.sort { $0.date < $1.date }
            chats[contactKey] = thread
            if let ch { channelUnread[ch, default: 0] += 1 } else { unread[contactKey, default: 0] += 1 }
            Notifier.notify(title: "Message hors-ligne de \(name(for: contactKey))",
                            body: att != nil ? "📎 \(att!.fileName)" : text)
        default:
            break
        }
    }

    /// Si le contact est hors ligne et le relai activé, dépose le message
    /// chiffré sur kDrive. Appelée depuis `deliver()` en complément du send P2P.
    func enqueueRelayIfOffline(messageID: UUID, payload: [String: Any], to contactKey: String) {
        guard !isOnline(contactKey) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        Task {
            do {
                try await KDriveRelay.shared.enqueue(to: contactKey,
                                                     messageID: messageID.uuidString,
                                                     payload: data)
            } catch {
                // Pas bloquant : le message reste dans l'outbox local et sera
                // ré-envoyé en direct au retour en ligne du contact.
            }
        }
    }
}

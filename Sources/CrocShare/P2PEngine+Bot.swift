import Foundation
import SwiftUI

// Contact « 🤖 Robot » pour tester le chat sans pair réel.
//
// • Toujours en ligne (présent dans `peers`).
// • Répond automatiquement à chaque message avec une banque de réponses
//   simples + commandes spéciales (`/help`, `/file`, `/long`, `/react`).
// • Persiste comme un contact normal : pour le retirer, clic droit →
//   « Supprimer le contact » dans la sidebar, ou via Réglages.
//
// La clé du bot n'est PAS une vraie pubkey Hyperswarm — c'est une chaîne
// reconnaissable. Aucun trafic réseau n'est généré pour cette « identité ».

extension P2PEngine {

    /// Préfixe non valide en z32 pour identifier sans ambiguïté la clé du bot.
    public static let botKey = "robot-test-bot-00000000000000000000000000000000000000000000000"

    public var hasBot: Bool { contacts.contains(Self.botKey) }

    /// Ajoute le contact bot. Idempotent.
    public func addBot() {
        guard !hasBot else { return }
        contacts.append(Self.botKey)
        contactNames[Self.botKey] = "🤖 Robot"
        // Toujours en ligne.
        if !peers.contains(where: { $0.key == Self.botKey }) {
            peers.append(P2PPeer(key: Self.botKey, direct: true))
        }
        // Message d'accueil.
        let welcome = P2PMessage(
            id: UUID(), fromMe: false, fromName: "🤖 Robot",
            text: "Salut ! Tape `/help` pour voir ce que je sais faire.",
            date: Date(), delivered: true, attachment: nil,
            fromKey: Self.botKey, replyTo: nil)
        chats[Self.botKey, default: []].append(welcome)
        unread[Self.botKey, default: 0] += 1
    }

    public func removeBot() {
        contacts.removeAll { $0 == Self.botKey }
        contactNames[Self.botKey] = nil
        chats[Self.botKey] = nil
        unread[Self.botKey] = nil
        peers.removeAll { $0.key == Self.botKey }
    }

    /// Au démarrage, restaurer la présence du bot si l'utilisateur l'avait
    /// ajouté lors d'une session précédente.
    func restoreBotPresenceIfNeeded() {
        if hasBot && !peers.contains(where: { $0.key == Self.botKey }) {
            peers.append(P2PPeer(key: Self.botKey, direct: true))
        }
    }

    /// Appelé par `send()` quand le destinataire est le bot. Génère une
    /// réponse différée pour simuler un échange réel.
    func botRespond(to userText: String) {
        let reply = botCannedResponse(for: userText)
        DispatchQueue.main.asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self else { return }
            let msg = P2PMessage(
                id: UUID(), fromMe: false, fromName: "🤖 Robot",
                text: reply.text, date: Date(), delivered: true,
                attachment: reply.attachment,
                fromKey: Self.botKey, replyTo: nil)
            self.chats[Self.botKey, default: []].append(msg)
            self.unread[Self.botKey, default: 0] += 1
            Notifier.notify(title: "🤖 Robot", body: reply.text)
        }
    }

    private struct BotReply { var text: String; var delay: TimeInterval; var attachment: P2PAttachment? = nil }

    private func botCannedResponse(for input: String) -> BotReply {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.hasPrefix("/help") {
            return BotReply(text: """
            Commandes :
            • `/help` — cette aide
            • `/long` — un message multi-ligne pour tester la mise en page
            • `/markdown` — un message **gras** et *italique* avec [un lien](https://crocshare.app)
            • `/file` — t'envoie une petite pièce jointe factice
            • `/react` — je place quelques réactions sur ton dernier message
            • `/clear` — efface notre conversation
            Sinon je réponds n'importe quoi de cohérent 😄
            """, delay: 0.6)
        }
        if trimmed.hasPrefix("/long") {
            return BotReply(text: (0..<8).map { "Ligne \($0+1) — lorem ipsum dolor sit amet." }.joined(separator: "\n"),
                            delay: 0.7)
        }
        if trimmed.hasPrefix("/markdown") {
            return BotReply(text: "Voici **du gras**, *de l'italique*, `du code inline`, et [un lien](https://crocshare.app).",
                            delay: 0.5)
        }
        if trimmed.hasPrefix("/file") {
            // Pièce jointe factice : pas de fichier réel, juste pour vérifier l'affichage.
            let att = P2PAttachment(fileName: "demo.txt", relPath: "robot/demo.txt", size: 1234)
            return BotReply(text: "Tiens, un fichier de démonstration.", delay: 0.8, attachment: att)
        }
        if trimmed.hasPrefix("/react") {
            // Pose quelques réactions sur le dernier message utilisateur.
            if let last = chats[Self.botKey]?.last(where: { $0.fromMe }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    for emoji in ["👍", "🎉", "🔥"] {
                        var byEmoji = self.reactions[last.id] ?? [:]
                        var reactors = byEmoji[emoji] ?? []
                        if !reactors.contains(Self.botKey) { reactors.append(Self.botKey) }
                        byEmoji[emoji] = reactors
                        self.reactions[last.id] = byEmoji
                    }
                }
            }
            return BotReply(text: "Voilà, j'ai mis quelques réactions sur ton dernier message ✨", delay: 0.5)
        }
        if trimmed.hasPrefix("/clear") {
            chats[Self.botKey] = []
            return BotReply(text: "Conversation effacée. On repart à zéro.", delay: 0.2)
        }

        // Pas de commande : réponse "smart" variée, on évite de répéter la
        // dernière utilisée pour ne pas spammer.
        let pool: [String] = [
            "Reçu ! 🤖",
            "Bien noté.",
            "Intéressant, dis-m'en plus.",
            "Hmm, ok.",
            "Tape `/help` si tu veux voir ce que je fais.",
            "Je suis un bot local — aucun message n'est envoyé sur le réseau.",
            "👍",
            "Tu testes le chat ? Parfait."
        ]
        let last = chats[Self.botKey]?.last(where: { !$0.fromMe })?.text
        let pick = pool.filter { $0 != last }.randomElement() ?? pool.first!
        // Délai aléatoire 0.4s–1.4s pour ne pas être instantané.
        return BotReply(text: pick, delay: TimeInterval.random(in: 0.4...1.4))
    }
}

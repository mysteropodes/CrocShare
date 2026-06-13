import Foundation
import SwiftUI
import AppKit
import CryptoKit

/// Moteur expérimental P2P. Pilote le compagnon via CoreBridge, gère la seed
/// au Trousseau, et — Phase 2 — porte un vrai chat texte sur le tunnel
/// Hyperswarm : persistance locale, accusés de réception, file d'attente
/// hors-ligne (les messages non délivrés repartent à la reconnexion du pair).
/// Coexiste avec croc : n'altère ni les contacts croc ni la synchro existante.
@MainActor
final class P2PEngine: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, ready, reconnecting(Int), failed(String)
    }

    struct P2PPeer: Identifiable, Hashable {
        let key: String
        var direct: Bool
        var id: String { key }
    }

    /// Message de chat P2P (texte). id partagé entre les deux pairs pour la
    /// déduplication et les accusés.
    struct P2PMessage: Identifiable, Codable, Hashable {
        var id: UUID
        var fromMe: Bool
        var fromName: String
        var text: String
        var date: Date
        var delivered: Bool
    }

    @Published var status: Status = .stopped
    @Published var myPublicKey: String = ""
    @Published var peers: [P2PPeer] = []
    @Published var inviteCode: String = ""
    @Published var contacts: [String] = []
    /// Conversations P2P, indexées par clé publique (z32) du contact.
    @Published var chats: [String: [P2PMessage]] = [:] { didSet { saveChats() } }
    @Published var contactNames: [String: String] = [:] { didSet { saveNames() } }
    @Published var unread: [String: Int] = [:]
    @Published var log: [String] = []

    var myName: String = ""
    private var bridge: CoreBridge?
    private var eventTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private var chatsURL: URL { AppStore.supportDir.appendingPathComponent("p2p-chats.json") }
    private var namesURL: URL { AppStore.supportDir.appendingPathComponent("p2p-names.json") }

    init() {
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: chatsURL),
           let map = try? dec.decode([String: [P2PMessage]].self, from: data) {
            chats = map
        }
        if let data = try? Data(contentsOf: namesURL),
           let map = try? dec.decode([String: String].self, from: data) {
            contactNames = map
        }
    }

    func isOnline(_ key: String) -> Bool { peers.contains { $0.key == key } }
    func name(for key: String) -> String { contactNames[key] ?? String(key.prefix(8)) }

    /// UUID stable dérivé d'une clé z32 (pour réutiliser AvatarView, couleurs…).
    static func uuid(forKey key: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
        var bytes = [UInt8](digest)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Cycle de vie

    func enable(displayName: String) {
        guard bridge == nil else { return }
        myName = displayName
        status = .starting
        let bridge = CoreBridge(storagePath: CorePaths.storagePath)
        self.bridge = bridge
        consumeEvents(of: bridge)

        Task {
            do {
                let seed = Keychain.getIdentitySeed()
                let result = try await bridge.start(seed: seed, displayName: displayName)
                if let newSeed = result["seed"] as? String { Keychain.setIdentitySeed(newSeed) }
                myPublicKey = result["publicKey"] as? String ?? ""
                status = .ready
                await refreshContacts()
                addLog("Compagnon prêt — identité \(myPublicKey.prefix(12))…")
            } catch {
                status = .failed(error.localizedDescription)
                addLog("Échec démarrage : \(error.localizedDescription)")
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { try? await self?.bridge?.request("swarm.connectAll") }
        }
    }

    func disable() {
        eventTask?.cancel(); eventTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        let bridge = self.bridge
        self.bridge = nil
        status = .stopped
        peers = []; inviteCode = ""; myPublicKey = ""; contacts = []
        Task { await bridge?.stop() }
    }

    private func consumeEvents(of bridge: CoreBridge) {
        eventTask = Task { [weak self] in
            for await event in bridge.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CoreEvent) {
        switch event.event {
        case "core.ready":
            myPublicKey = event.params["publicKey"] as? String ?? myPublicKey
            status = .ready
        case "core.reconnecting":
            let s = event.params["inSeconds"] as? Int ?? 1
            status = .reconnecting(s)
        case "peer.connected":
            if let key = event.params["contactKey"] as? String {
                let direct = event.params["direct"] as? Bool ?? false
                if let name = event.params["name"] as? String, !name.isEmpty {
                    contactNames[key] = name
                }
                peers.removeAll { $0.key == key }
                peers.append(P2PPeer(key: key, direct: direct))
                if !contacts.contains(key) { contacts.append(key) }
                addLog("Connecté à \(name(for: key)) (\(direct ? "direct" : "relayé"))")
                flushOutbox(to: key)   // file d'attente hors-ligne
            }
        case "peer.disconnected":
            if let key = event.params["contactKey"] as? String {
                peers.removeAll { $0.key == key }
                addLog("Déconnecté de \(name(for: key))")
            }
        case "pairing.peerJoined":
            if let key = event.params["contactKey"] as? String {
                inviteCode = ""
                if !contacts.contains(key) { contacts.append(key) }
                addLog("Appairé avec \(name(for: key))")
                Task { await refreshContacts() }
            }
        case "peer.message":
            if let key = event.params["contactKey"] as? String {
                handlePayload(event.params["payload"] as? [String: Any] ?? [:], from: key)
            }
        case "core.error":
            addLog("Erreur core : \(event.params["message"] as? String ?? "?")")
        default:
            break
        }
    }

    // MARK: - Chat (Phase 2)

    private func handlePayload(_ payload: [String: Any], from key: String) {
        switch payload["k"] as? String {
        case "msg":
            guard let idStr = payload["id"] as? String, let id = UUID(uuidString: idStr) else { return }
            let text = payload["t"] as? String ?? ""
            let date = (payload["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            var thread = chats[key] ?? []
            if !thread.contains(where: { $0.id == id }) {
                thread.append(P2PMessage(id: id, fromMe: false, fromName: name(for: key),
                                         text: text, date: date, delivered: true))
                thread.sort { $0.date < $1.date }
                chats[key] = thread
                unread[key, default: 0] += 1
                Notifier.notify(title: "Message P2P de \(name(for: key))", body: text)
            }
            // Accusé de réception.
            Task { try? await bridge?.request("peer.send",
                ["contactKey": key, "payload": ["k": "ack", "ids": [idStr]]]) }
        case "ack":
            let ids = Set((payload["ids"] as? [String] ?? []).compactMap { UUID(uuidString: $0) })
            guard var thread = chats[key], !ids.isEmpty else { return }
            var changed = false
            for i in thread.indices where thread[i].fromMe && !thread[i].delivered && ids.contains(thread[i].id) {
                thread[i].delivered = true; changed = true
            }
            if changed { chats[key] = thread }
        default:
            break
        }
    }

    func send(_ text: String, to key: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = P2PMessage(id: UUID(), fromMe: true, fromName: myName,
                             text: trimmed, date: Date(), delivered: false)
        chats[key, default: []].append(msg)
        deliver(msg, to: key)
    }

    private func deliver(_ msg: P2PMessage, to key: String) {
        let payload: [String: Any] = [
            "k": "msg", "id": msg.id.uuidString, "t": msg.text,
            "ts": msg.date.timeIntervalSince1970 * 1000
        ]
        Task {
            _ = try? await bridge?.request("peer.send", ["contactKey": key, "payload": payload])
            // Délivré confirmé par l'ack ; sinon renvoyé à la prochaine connexion.
        }
    }

    /// Renvoie les messages non encore confirmés à un pair qui vient de se connecter.
    private func flushOutbox(to key: String) {
        for msg in (chats[key] ?? []) where msg.fromMe && !msg.delivered {
            deliver(msg, to: key)
        }
    }

    func markRead(_ key: String) { unread[key] = 0 }

    // MARK: - Appairage / actions

    func createInvite() {
        Task {
            do {
                let res = try await bridge?.request("pairing.createInvite")
                inviteCode = res?["invite"] as? String ?? ""
                addLog("Invitation créée")
            } catch { addLog("createInvite: \(error.localizedDescription)") }
        }
    }

    func acceptInvite(_ code: String) {
        Task {
            do {
                let res = try await bridge?.request("pairing.acceptInvite", ["invite": code], timeout: 50)
                if let key = res?["contactKey"] as? String {
                    if let nm = res?["name"] as? String, !nm.isEmpty { contactNames[key] = nm }
                    if !contacts.contains(key) { contacts.append(key) }
                    addLog("Appairé via code → \(name(for: key))")
                }
                await refreshContacts()
            } catch { addLog("acceptInvite: \(error.localizedDescription)") }
        }
    }

    func ping(_ key: String) {
        Task {
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            let res = try? await bridge?.request("peer.send",
                ["contactKey": key, "payload": ["k": "ping", "ts": ts]])
            addLog("Ping → \(name(for: key)) : \((res?["delivered"] as? Bool ?? false) ? "délivré" : "hors ligne")")
        }
    }

    private func refreshContacts() async {
        if let res = try? await bridge?.request("contacts.list"),
           let list = res["contacts"] as? [[String: Any]] {
            let keys = list.compactMap { $0["key"] as? String }
            for k in keys where !contacts.contains(k) { contacts.append(k) }
        }
    }

    // MARK: - Persistance

    private func saveChats() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(chats) { try? data.write(to: chatsURL) }
    }
    private func saveNames() {
        if let data = try? JSONEncoder().encode(contactNames) { try? data.write(to: namesURL) }
    }

    private func addLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

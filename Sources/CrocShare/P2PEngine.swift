import Foundation
import SwiftUI
import AppKit

/// Moteur expérimental P2P (Phase 1). Pilote le compagnon via CoreBridge,
/// gère la seed au Trousseau, et expose l'état au panneau de réglages.
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

    @Published var status: Status = .stopped
    @Published var myPublicKey: String = ""
    @Published var peers: [P2PPeer] = []
    @Published var inviteCode: String = ""
    @Published var contacts: [String] = []
    @Published var log: [String] = []

    private var bridge: CoreBridge?
    private var eventTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    func enable() {
        guard bridge == nil else { return }
        status = .starting
        let bridge = CoreBridge(storagePath: CorePaths.storagePath)
        self.bridge = bridge
        consumeEvents(of: bridge)

        Task {
            do {
                let seed = Keychain.getIdentitySeed()
                let result = try await bridge.start(seed: seed)
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

        // Reconnexion au réveil de veille (§7).
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
            for await event in await bridge.events {
                await self?.handle(event)
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
            addLog("Reconnexion dans \(s)s…")
        case "peer.connected":
            if let key = event.params["contactKey"] as? String {
                let direct = event.params["direct"] as? Bool ?? false
                peers.removeAll { $0.key == key }
                peers.append(P2PPeer(key: key, direct: direct))
                addLog("Connecté à \(key.prefix(12))… (\(direct ? "direct" : "relayé"))")
            }
        case "peer.disconnected":
            if let key = event.params["contactKey"] as? String {
                peers.removeAll { $0.key == key }
                addLog("Déconnecté de \(key.prefix(12))…")
            }
        case "pairing.peerJoined":
            if let key = event.params["contactKey"] as? String {
                inviteCode = ""
                addLog("Appairé avec \(key.prefix(12))…")
                Task { await refreshContacts() }
            }
        case "peer.message":
            if let key = event.params["contactKey"] as? String {
                let payload = event.params["payload"] as? [String: Any] ?? [:]
                addLog("Message de \(key.prefix(8))… : \(payload)")
            }
        case "core.error":
            addLog("Erreur core : \(event.params["message"] as? String ?? "?")")
        default:
            break
        }
    }

    // MARK: - Actions

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
                addLog("Appairé via code → \((res?["contactKey"] as? String ?? "").prefix(12))…")
                await refreshContacts()
            } catch { addLog("acceptInvite: \(error.localizedDescription)") }
        }
    }

    func ping(_ key: String) {
        Task {
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            do {
                let res = try await bridge?.request("peer.send",
                    ["contactKey": key, "payload": ["t": "ping", "ts": ts]])
                addLog("Ping → \(key.prefix(8))… : \((res?["delivered"] as? Bool ?? false) ? "délivré" : "hors ligne")")
            } catch { addLog("ping: \(error.localizedDescription)") }
        }
    }

    private func refreshContacts() async {
        if let res = try? await bridge?.request("contacts.list"),
           let list = res["contacts"] as? [[String: Any]] {
            contacts = list.compactMap { $0["key"] as? String }
        }
    }

    private func addLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

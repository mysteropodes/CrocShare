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

    /// Pièce jointe d'un message P2P (le fichier vit dans le dossier partagé de
    /// l'expéditeur sous Chat/… et se télécharge via le même mécanisme que les fichiers).
    struct P2PAttachment: Codable, Hashable {
        var fileName: String
        var relPath: String
        var size: Int64
        var isImage: Bool {
            ["png","jpg","jpeg","gif","heic","webp","tiff"].contains((fileName as NSString).pathExtension.lowercased())
        }
        var isVideo: Bool {
            ["mp4","mov","m4v"].contains((fileName as NSString).pathExtension.lowercased())
        }
        var isRive: Bool { (fileName as NSString).pathExtension.lowercased() == "riv" }
    }

    /// Message de chat P2P. id partagé entre pairs (dédup + accusés).
    /// `channel` = nil pour un message direct, sinon id du salon.
    struct P2PMessage: Identifiable, Codable, Hashable {
        var id: UUID
        var fromMe: Bool
        var fromName: String
        var text: String
        var date: Date
        var delivered: Bool
        var channel: UUID? = nil
        var attachment: P2PAttachment? = nil
        /// Clé z32 de l'expéditeur (pour télécharger les pièces jointes de salon).
        var fromKey: String? = nil
    }

    /// Salon façon Slack : un nom + des membres (clés P2P).
    struct P2PChannel: Identifiable, Codable, Hashable {
        var id: UUID
        var name: String
        var memberKeys: [String]
        var createdBy: String
    }

    enum PairingState: Equatable {
        case idle, hosting, joining, success(String), failed(String)
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

    /// Téléchargement P2P (file d'attente hors-ligne comme côté croc).
    struct P2PDownload: Identifiable, Hashable {
        var id: UUID
        var contactKey: String
        var relPath: String
        var size: Int64
        var status: PendingDownload.Status
        var name: String { (relPath as NSString).lastPathComponent }
    }

    /// Listes de fichiers partagés reçues des contacts (clé z32 → fichiers).
    @Published var remoteFiles: [String: [RemoteFile]] = [:]
    @Published var fileDownloads: [P2PDownload] = []
    @Published var pairingState: PairingState = .idle
    @Published var channels: [P2PChannel] = [] { didSet { saveChannels() } }
    @Published var channelUnread: [UUID: Int] = [:]

    var myName: String = ""
    var sharedFolder: String?
    var downloadBase: String?
    /// reqId → (clé contact, chemin) pour router les fichiers reçus.
    private var fileReqs: [String: (key: String, relPath: String)] = [:]
    private var bridge: CoreBridge?
    private var eventTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private var chatsURL: URL { AppStore.supportDir.appendingPathComponent("p2p-chats.json") }
    private var namesURL: URL { AppStore.supportDir.appendingPathComponent("p2p-names.json") }
    private var channelsURL: URL { AppStore.supportDir.appendingPathComponent("p2p-channels.json") }

    private func saveChannels() {
        if let data = try? JSONEncoder().encode(channels) { try? data.write(to: channelsURL) }
    }

    init() {
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: channelsURL),
           let list = try? dec.decode([P2PChannel].self, from: data) {
            channels = list
        }
        if let data = try? Data(contentsOf: chatsURL),
           let map = try? dec.decode([String: [P2PMessage]].self, from: data) {
            chats = map
        }
        if let data = try? Data(contentsOf: namesURL),
           let map = try? dec.decode([String: String].self, from: data) {
            contactNames = map
        }
    }

    var isReady: Bool { if case .ready = status { return true }; return false }
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
                flushOutbox(to: key)        // chat en attente
                sendManifest(to: key)       // ma liste de fichiers
                flushDownloads(to: key)     // téléchargements en attente
                syncChannels(to: key)       // définitions de salons
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
                pairingState = .success(name(for: key))
                Task { await refreshContacts() }
            }
        case "peer.message":
            if let key = event.params["contactKey"] as? String {
                handlePayload(event.params["payload"] as? [String: Any] ?? [:], from: key)
            }
        case "peer.fileReceived":
            receiveFile(event.params)
        case "peer.fileSendFailed":
            addLog("Envoi fichier échoué : \(event.params["reason"] as? String ?? "?")")
        case "core.error":
            addLog("Erreur core : \(event.params["message"] as? String ?? "?")")
        default:
            break
        }
    }

    // MARK: - Chat (Phase 2)

    private func handlePayload(_ payload: [String: Any], from key: String) {
        switch payload["k"] as? String {
        case "manifest":
            if let json = payload["json"] as? String, let d = json.data(using: .utf8),
               let files = try? JSONDecoder().decode([RemoteFile].self, from: d) {
                remoteFiles[key] = files
            }
        case "freq":
            if let reqId = payload["reqId"] as? String, let rel = payload["relPath"] as? String {
                serveFile(reqId: reqId, relPath: rel, to: key)
            }
        case "chan":
            if let json = payload["json"] as? String, let d = json.data(using: .utf8),
               let chan = try? JSONDecoder().decode(P2PChannel.self, from: d) {
                ingestChannel(chan)
            }
        case "msg":
            guard let idStr = payload["id"] as? String, let id = UUID(uuidString: idStr) else { return }
            let text = payload["t"] as? String ?? ""
            let date = (payload["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let ch = (payload["ch"] as? String).flatMap { UUID(uuidString: $0) }
            var att: P2PAttachment?
            if let a = payload["att"] as? [String: Any], let fn = a["fileName"] as? String,
               let rp = a["relPath"] as? String {
                let sz = (a["size"] as? NSNumber)?.int64Value ?? Int64(a["size"] as? Int ?? 0)
                att = P2PAttachment(fileName: fn, relPath: rp, size: sz)
            }
            var thread = chats[key] ?? []
            if !thread.contains(where: { $0.id == id }) {
                thread.append(P2PMessage(id: id, fromMe: false, fromName: name(for: key),
                                         text: text, date: date, delivered: true,
                                         channel: ch, attachment: att, fromKey: key))
                thread.sort { $0.date < $1.date }
                chats[key] = thread
                if let ch { channelUnread[ch, default: 0] += 1 } else { unread[key, default: 0] += 1 }
                let title = ch.flatMap { cid in channels.first { $0.id == cid } }
                    .map { "#\($0.name) — \(name(for: key))" } ?? "Message P2P de \(name(for: key))"
                Notifier.notify(title: title, body: att != nil ? "📎 \(att!.fileName)" : text)
                if let att, att.isImage || att.isVideo {
                    downloadFile(RemoteFile(path: att.relPath, size: att.size, mtime: date), from: key)
                }
            }
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

    func send(_ text: String, attachment: P2PAttachment? = nil, to key: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachment != nil else { return }
        let msg = P2PMessage(id: UUID(), fromMe: true, fromName: myName,
                             text: trimmed, date: Date(), delivered: false,
                             attachment: attachment, fromKey: myPublicKey)
        chats[key, default: []].append(msg)
        deliver(msg, to: key)
    }

    /// Message de salon : même id partagé, déposé dans le fil de chaque membre
    /// (réutilise la file d'attente/accusés du chat direct ; vue salon dédupe par id).
    func sendChannelMessage(_ text: String, attachment: P2PAttachment? = nil, in channel: P2PChannel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachment != nil else { return }
        let id = UUID()
        let now = Date()
        for memberKey in channel.memberKeys where memberKey != myPublicKey {
            let msg = P2PMessage(id: id, fromMe: true, fromName: myName, text: trimmed,
                                 date: now, delivered: false, channel: channel.id,
                                 attachment: attachment, fromKey: myPublicKey)
            chats[memberKey, default: []].append(msg)
            deliver(msg, to: memberKey)
        }
    }

    private func deliver(_ msg: P2PMessage, to key: String) {
        var payload: [String: Any] = [
            "k": "msg", "id": msg.id.uuidString, "t": msg.text,
            "ts": msg.date.timeIntervalSince1970 * 1000
        ]
        if let ch = msg.channel { payload["ch"] = ch.uuidString }
        if let a = msg.attachment {
            payload["att"] = ["fileName": a.fileName, "relPath": a.relPath, "size": a.size]
        }
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

    func removeContact(_ key: String) {
        contacts.removeAll { $0 == key }
        contactNames[key] = nil
        chats[key] = nil
        remoteFiles[key] = nil
        unread[key] = nil
        peers.removeAll { $0.key == key }
        Task { try? await bridge?.request("contacts.remove", ["contactKey": key]) }
    }

    var totalUnread: Int { unread.values.reduce(0, +) }

    // MARK: - Salons (Slack-like) sur P2P

    func createChannel(name: String, memberKeys: [String]) {
        let chan = P2PChannel(id: UUID(), name: name, memberKeys: memberKeys, createdBy: myPublicKey)
        channels.append(chan)
        for k in memberKeys where k != myPublicKey { sendChannelDef(chan, to: k) }
    }

    func updateChannelMembers(_ id: UUID, memberKeys: [String]) {
        guard let i = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[i].memberKeys = memberKeys
        for k in memberKeys where k != myPublicKey { sendChannelDef(channels[i], to: k) }
    }

    func removeChannel(_ id: UUID) {
        channels.removeAll { $0.id == id }
        channelUnread[id] = nil
    }

    private func ingestChannel(_ chan: P2PChannel) {
        if let i = channels.firstIndex(where: { $0.id == chan.id }) {
            if channels[i] != chan { channels[i] = chan }
        } else {
            channels.append(chan)
            Notifier.notify(title: "Nouveau salon", body: "Tu as été ajouté à #\(chan.name)")
        }
    }

    private func sendChannelDef(_ chan: P2PChannel, to key: String) {
        guard let data = try? JSONEncoder().encode(chan), let json = String(data: data, encoding: .utf8) else { return }
        Task { try? await bridge?.request("peer.send", ["contactKey": key, "payload": ["k": "chan", "json": json]]) }
    }

    private func syncChannels(to key: String) {
        for chan in channels where chan.createdBy == myPublicKey && chan.memberKeys.contains(key) {
            sendChannelDef(chan, to: key)
        }
    }

    func messages(in channel: P2PChannel) -> [P2PMessage] {
        var seen = Set<UUID>()
        return channel.memberKeys.flatMap { chats[$0] ?? [] }
            .filter { $0.channel == channel.id }
            .sorted { $0.date < $1.date }
            .filter { seen.insert($0.id).inserted }
    }

    func markChannelRead(_ id: UUID) { channelUnread[id] = 0 }

    // MARK: - Pièces jointes du chat

    /// Copie un fichier déposé dans le chat vers le dossier partagé (Chat/<scope>/).
    func importChatFile(_ url: URL, scope: String) -> P2PAttachment? {
        guard let shared = sharedFolder else { return nil }
        let fm = FileManager.default
        let safe = scope.replacingOccurrences(of: "/", with: "-")
        let destDir = URL(fileURLWithPath: shared).appendingPathComponent("Chat").appendingPathComponent(safe)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = url.pathExtension
        var name = url.lastPathComponent
        var dest = destDir.appendingPathComponent(name); var n = 1
        while fm.fileExists(atPath: dest.path) {
            name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            dest = destDir.appendingPathComponent(name); n += 1
        }
        do { try fm.copyItem(at: url, to: dest) } catch { return nil }
        let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        return P2PAttachment(fileName: name, relPath: "Chat/\(safe)/\(name)", size: size)
    }

    /// URL locale d'une pièce jointe (mienne = dossier partagé ; reçue = dossier de réception).
    func attachmentURL(_ msg: P2PMessage) -> URL? {
        guard let att = msg.attachment else { return nil }
        if msg.fromMe {
            return sharedFolder.map { URL(fileURLWithPath: $0).appendingPathComponent(att.relPath) }
        }
        guard let base = downloadBase, let fk = msg.fromKey else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(name(for: fk)).appendingPathComponent(att.relPath)
    }

    func attachmentDownloaded(_ msg: P2PMessage) -> Bool {
        guard let u = attachmentURL(msg) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    func downloadAttachment(_ msg: P2PMessage) {
        guard let att = msg.attachment, let fk = msg.fromKey, !msg.fromMe else { return }
        downloadFile(RemoteFile(path: att.relPath, size: att.size, mtime: msg.date), from: fk)
    }

    // MARK: - Fichiers (Phase 4) — partage à la demande sur le tunnel P2P

    func configure(sharedFolder: String?, downloadBase: String?) {
        self.sharedFolder = sharedFolder
        self.downloadBase = downloadBase
    }

    /// Scanne mon dossier partagé (exclut le dossier de réception et les .croc).
    private func buildManifest() -> [RemoteFile] {
        guard let path = sharedFolder else { return [] }
        let root = URL(fileURLWithPath: path)
        let dlRoot = (downloadBase.map { URL(fileURLWithPath: $0) })?.standardizedFileURL.path
        var files: [RemoteFile] = []
        if let en = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                let p = url.standardizedFileURL.path
                if let dlRoot, p == dlRoot || p.hasPrefix(dlRoot + "/") { en.skipDescendants(); continue }
                guard url.pathExtension != "croc",
                      let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      v.isRegularFile == true else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                files.append(RemoteFile(path: rel, size: Int64(v.fileSize ?? 0),
                                        mtime: v.contentModificationDate ?? Date()))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    func sendManifest(to key: String) {
        let files = buildManifest()
        guard let data = try? JSONEncoder().encode(files),
              let json = String(data: data, encoding: .utf8) else { return }
        Task { try? await bridge?.request("peer.send",
            ["contactKey": key, "payload": ["k": "manifest", "json": json]]) }
    }

    /// Sert un fichier demandé (résolu dans mon dossier partagé, anti-traversée).
    private func serveFile(reqId: String, relPath: String, to key: String) {
        guard let shared = sharedFolder else { return }
        let root = URL(fileURLWithPath: shared).standardizedFileURL
        let abs = root.appendingPathComponent(relPath).standardizedFileURL
        guard abs.path == root.path || abs.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: abs.path) else { return }
        Task { try? await bridge?.request("peer.sendFile",
            ["contactKey": key, "reqId": reqId, "relPath": relPath, "absPath": abs.path]) }
    }

    func downloadFile(_ file: RemoteFile, from key: String) {
        let active = fileDownloads.contains {
            $0.contactKey == key && $0.relPath == file.path
                && ($0.status == .waiting || $0.status == .transferring)
        }
        guard !active else { return }
        fileDownloads.append(P2PDownload(id: UUID(), contactKey: key, relPath: file.path,
                                         size: file.size, status: .waiting))
        if isOnline(key) { startDownload(key: key, relPath: file.path) }
        else { Notifier.notify(title: "Mis en attente",
                               body: "\(file.name) sera téléchargé dès que \(name(for: key)) sera en ligne.") }
    }

    private func flushDownloads(to key: String) {
        for d in fileDownloads where d.contactKey == key && d.status == .waiting {
            startDownload(key: key, relPath: d.relPath)
        }
    }

    private func startDownload(key: String, relPath: String) {
        setDownloadStatus(key: key, relPath: relPath, .transferring)
        let reqId = UUID().uuidString
        fileReqs[reqId] = (key, relPath)
        Task { try? await bridge?.request("peer.send",
            ["contactKey": key, "payload": ["k": "freq", "reqId": reqId, "relPath": relPath]]) }
    }

    private func receiveFile(_ params: [String: Any]) {
        guard let reqId = params["reqId"] as? String,
              let tmp = params["tmpPath"] as? String,
              let info = fileReqs[reqId] else { return }
        fileReqs[reqId] = nil
        let key = info.key
        let relPath = info.relPath
        let base = downloadBase ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrocShare").path
        let dest = URL(fileURLWithPath: base)
            .appendingPathComponent(name(for: key))
            .appendingPathComponent(relPath)
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: URL(fileURLWithPath: tmp), to: dest)
            setDownloadStatus(key: key, relPath: relPath, .done)
            Notifier.notify(title: "Téléchargement terminé",
                            body: "\((relPath as NSString).lastPathComponent) reçu de \(name(for: key))")
        } catch {
            setDownloadStatus(key: key, relPath: relPath, .failed)
        }
    }

    private func setDownloadStatus(key: String, relPath: String, _ status: PendingDownload.Status) {
        if let i = fileDownloads.firstIndex(where: {
            $0.contactKey == key && $0.relPath == relPath
                && ($0.status == .waiting || $0.status == .transferring)
        }) {
            fileDownloads[i].status = status
        }
    }

    func isDownloaded(_ relPath: String, from key: String) -> Bool {
        guard let base = downloadBase else { return false }
        let p = URL(fileURLWithPath: base).appendingPathComponent(name(for: key)).appendingPathComponent(relPath)
        return FileManager.default.fileExists(atPath: p.path)
    }

    // MARK: - Appairage / actions

    func createInvite() {
        pairingState = .hosting
        Task {
            do {
                let res = try await bridge?.request("pairing.createInvite")
                inviteCode = res?["invite"] as? String ?? ""
                addLog("Invitation créée")
            } catch {
                pairingState = .failed(error.localizedDescription)
                addLog("createInvite: \(error.localizedDescription)")
            }
        }
    }

    func acceptInvite(_ code: String) {
        pairingState = .joining
        Task {
            do {
                let res = try await bridge?.request("pairing.acceptInvite", ["invite": code], timeout: 130)
                if let key = res?["contactKey"] as? String {
                    if let nm = res?["name"] as? String, !nm.isEmpty { contactNames[key] = nm }
                    if !contacts.contains(key) { contacts.append(key) }
                    addLog("Appairé via code → \(name(for: key))")
                    pairingState = .success(name(for: key))
                }
                await refreshContacts()
            } catch {
                pairingState = .failed("Aucune réponse — vérifie que ton contact a bien créé le code et qu'il est en ligne.")
                addLog("acceptInvite: \(error.localizedDescription)")
            }
        }
    }

    func resetPairing() { pairingState = .idle; inviteCode = "" }

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

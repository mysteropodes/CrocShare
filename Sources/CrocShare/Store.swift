import Foundation
import SwiftUI

/// État central de l'app : contacts, manifests reçus, file d'attente, config.
/// Tout est persisté en JSON dans ~/Library/Application Support/CrocShare/.
@MainActor
final class AppStore: ObservableObject {
    @Published var contacts: [Contact] = [] { didSet { saveContacts() } }
    @Published var downloads: [PendingDownload] = [] { didSet { saveDownloads() } }
    @Published var manifests: [UUID: Manifest] = [:] { didSet { saveManifests() } }
    @Published var chats: [UUID: [ChatMessage]] = [:] { didSet { saveChats() } }
    @Published var channels: [Channel] = [] { didSet { saveChannels() } }
    @Published var lastSeen: [UUID: Date] = [:]
    /// Date de dernière lecture par conversation (id de contact ou de canal).
    @Published var lastRead: [UUID: Date] = [:] { didSet { saveLastRead() } }
    @Published var config = AppConfig() {
        didSet {
            saveConfig()
            applyRelayConfig()
        }
    }

    /// Si on héberge le relai nous-mêmes, l'app passe par localhost ;
    /// sinon par le relai personnalisé s'il est renseigné, sinon le public.
    func applyRelayConfig() {
        CrocService.customRelay = (config.hostRelay ?? false)
            ? "127.0.0.1:\(RelayServer.port)"
            : config.customRelay
    }
    @Published var crocPath: String? = CrocService.findCroc()

    static let supportDir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrocShare")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var contactsURL: URL { Self.supportDir.appendingPathComponent("contacts.json") }
    private var downloadsURL: URL { Self.supportDir.appendingPathComponent("queue.json") }
    private var configURL: URL { Self.supportDir.appendingPathComponent("config.json") }
    private var manifestsURL: URL { Self.supportDir.appendingPathComponent("manifests.json") }
    private var chatsURL: URL { Self.supportDir.appendingPathComponent("chats.json") }
    private var channelsURL: URL { Self.supportDir.appendingPathComponent("channels.json") }
    private var lastReadURL: URL { Self.supportDir.appendingPathComponent("lastread.json") }

    init() {
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? dec.decode(AppConfig.self, from: data) {
            config = cfg
        }
        applyRelayConfig()
        if let data = try? Data(contentsOf: contactsURL),
           let list = try? dec.decode([Contact].self, from: data) {
            // Les secrets vivent dans le trousseau ; le JSON n'en contient plus.
            // Migration : un JSON ancien avec secrets en clair est réécrit sans eux.
            var hadPlaintextSecrets = false
            contacts = list.map { contact in
                var contact = contact
                if contact.secret.isEmpty {
                    contact.secret = Keychain.get(for: contact.id) ?? ""
                } else {
                    hadPlaintextSecrets = true
                }
                return contact
            }
            if hadPlaintextSecrets { saveContacts() }
        }
        // JSON n'accepte que des clés String : les dictionnaires UUID sont convertis.
        if let data = try? Data(contentsOf: manifestsURL),
           let map = try? dec.decode([String: Manifest].self, from: data) {
            manifests = Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        if let data = try? Data(contentsOf: chatsURL),
           let map = try? dec.decode([String: [ChatMessage]].self, from: data) {
            chats = Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        if let data = try? Data(contentsOf: channelsURL),
           let list = try? dec.decode([Channel].self, from: data) {
            channels = list
        }
        if let data = try? Data(contentsOf: lastReadURL),
           let map = try? dec.decode([String: Date].self, from: data) {
            lastRead = Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        if let data = try? Data(contentsOf: downloadsURL),
           let list = try? dec.decode([PendingDownload].self, from: data) {
            // Un transfert interrompu par un quit repart en attente.
            downloads = list.map { item in
                var item = item
                if item.status == .transferring { item.status = .waiting }
                return item
            }
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) { try? data.write(to: url) }
    }

    private func saveContacts() {
        for contact in contacts where !contact.secret.isEmpty {
            Keychain.set(contact.secret, for: contact.id)
        }
        let sanitized = contacts.map { contact -> Contact in
            var contact = contact
            contact.secret = ""
            return contact
        }
        save(sanitized, to: contactsURL)
    }

    func removeContact(_ id: UUID) {
        Keychain.delete(for: id)
        contacts.removeAll { $0.id == id }
        manifests[id] = nil
        chats[id] = nil
        downloads.removeAll { $0.contactID == id }
    }
    private func saveDownloads() { save(downloads, to: downloadsURL) }
    private func saveConfig() { save(config, to: configURL) }
    private func saveManifests() {
        save(Dictionary(uniqueKeysWithValues: manifests.map { ($0.key.uuidString, $0.value) }),
             to: manifestsURL)
    }
    private func saveChats() {
        save(Dictionary(uniqueKeysWithValues: chats.map { ($0.key.uuidString, $0.value) }),
             to: chatsURL)
    }
    private func saveChannels() { save(channels, to: channelsURL) }
    private func saveLastRead() {
        save(Dictionary(uniqueKeysWithValues: lastRead.map { ($0.key.uuidString, $0.value) }),
             to: lastReadURL)
    }

    // MARK: - Non-lus

    func markRead(_ conversationID: UUID) {
        lastRead[conversationID] = Date()
    }

    func unreadCount(forContact id: UUID) -> Int {
        let since = lastRead[id] ?? .distantPast
        return (chats[id] ?? []).filter {
            $0.fromID != config.myID && $0.channelID == nil && $0.date > since
        }.count
    }

    func unreadCount(forChannel channel: Channel) -> Int {
        let since = lastRead[channel.id] ?? .distantPast
        return messages(in: channel).filter {
            $0.fromID != config.myID && $0.date > since
        }.count
    }

    var totalUnread: Int {
        contacts.reduce(0) { $0 + unreadCount(forContact: $1.id) }
            + channels.reduce(0) { $0 + unreadCount(forChannel: $1) }
    }

    // MARK: - Contact fictif (debug)

    static let debugContactID = UUID(uuidString: "DEBD0000-0000-0000-0000-000000000000")!

    var hasDebugContact: Bool {
        contacts.contains { $0.id == Self.debugContactID }
    }

    /// Crée un contact fictif « Démo » : en ligne en permanence, fausse liste de
    /// fichiers, réponses automatiques au chat, téléchargements simulés.
    func addDebugContact() {
        guard !hasDebugContact else { return }
        let id = Self.debugContactID
        let contact = Contact(id: id, name: "Démo (fictif)", secret: Channels.newSecret())
        contacts.append(contact)

        let now = Date()
        let files = [
            RemoteFile(path: "Documents/rapport-2026.pdf", size: 2_400_000, mtime: now.addingTimeInterval(-86400)),
            RemoteFile(path: "Documents/notes-reunion.txt", size: 4_200, mtime: now.addingTimeInterval(-3600)),
            RemoteFile(path: "Photos/Vacances/plage-01.jpg", size: 3_800_000, mtime: now.addingTimeInterval(-200000)),
            RemoteFile(path: "Photos/Vacances/plage-02.jpg", size: 4_100_000, mtime: now.addingTimeInterval(-200000)),
            RemoteFile(path: "Videos/demo-projet.mp4", size: 48_000_000, mtime: now.addingTimeInterval(-7200)),
            RemoteFile(path: "lisez-moi.txt", size: 880, mtime: now),
        ]
        manifests[id] = Manifest(senderID: id, senderName: "Démo (fictif)",
                                 files: files, generatedAt: now)
        if chats[id] == nil {
            chats[id] = [
                ChatMessage(id: UUID(), fromID: id, fromName: "Démo (fictif)",
                            text: "Salut ! Je suis un contact fictif pour tester l'app. 🤖",
                            date: now.addingTimeInterval(-60), delivered: false),
                ChatMessage(id: UUID(), fromID: id, fromName: "Démo (fictif)",
                            text: "Écris-moi, je réponds tout seul. Tu peux aussi télécharger mes fichiers ou m'en déposer un ici.",
                            date: now.addingTimeInterval(-55), delivered: false),
            ]
        }
        markSeen(id)
        if let manifest = manifests[id] {
            PlaceholderManager.sync(contact: contact, manifest: manifest,
                                    root: downloadFolderURL(for: contact))
        }
    }

    func removeDebugContact() {
        guard let contact = contacts.first(where: { $0.id == Self.debugContactID }) else { return }
        try? FileManager.default.removeItem(at: downloadFolderURL(for: contact))
        removeContact(contact.id)
    }

    /// Battement de cœur du contact fictif : présence, accusés, réponses, téléchargements.
    func debugTick() {
        guard let contact = contacts.first(where: { $0.id == Self.debugContactID }) else { return }
        markSeen(contact.id)

        // Accusés de réception + réponse automatique au dernier message.
        if var thread = chats[contact.id] {
            var changed = false
            for i in thread.indices where thread[i].fromID == config.myID && !thread[i].delivered {
                thread[i].delivered = true
                changed = true
            }
            if let last = thread.last, last.fromID == config.myID {
                let reply = last.attachment != nil
                    ? "🤖 Bien reçu ton fichier « \(last.attachment!.fileName) » !"
                    : "🤖 Bien reçu : « \(last.text) »"
                let replyMsg = ChatMessage(id: UUID(), fromID: contact.id, fromName: contact.name,
                                           text: reply, date: Date(), delivered: false,
                                           channelID: last.channelID)
                thread.append(replyMsg)
                changed = true
                notifyMessage(replyMsg)
            }
            if changed { chats[contact.id] = thread }
        }

        // Téléchargements simulés : le fichier est généré localement.
        let root = downloadFolderURL(for: contact)
        for item in downloads where item.contactID == contact.id {
            switch item.status {
            case .waiting:
                setDownloadStatus(item.id, .transferring)
            case .transferring:
                let dest = root.appendingPathComponent(item.filePath)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                let body = "Fichier de démonstration CrocShare — \(item.filePath)\n"
                try? Data(body.utf8).write(to: dest)
                PlaceholderManager.removeStub(for: item.filePath, root: root)
                setDownloadStatus(item.id, .done)
                Notifier.notify(title: "Téléchargement terminé",
                                body: "\((item.filePath as NSString).lastPathComponent) reçu de \(contact.name)")
            default:
                break
            }
        }
    }

    // MARK: - Présence

    /// Un contact est "en ligne" si on a reçu son manifest récemment.
    func isOnline(_ contact: Contact) -> Bool {
        guard let seen = lastSeen[contact.id] else { return false }
        return Date().timeIntervalSince(seen) < 120
    }

    func markSeen(_ contactID: UUID) {
        lastSeen[contactID] = Date()
    }

    // MARK: - Téléchargements

    func enqueueDownload(file: RemoteFile, contact: Contact) {
        let exists = downloads.contains {
            $0.contactID == contact.id && $0.filePath == file.path
                && ($0.status == .waiting || $0.status == .transferring)
        }
        guard !exists else { return }
        downloads.append(PendingDownload(
            id: UUID(), contactID: contact.id, filePath: file.path,
            size: file.size, createdAt: Date(), status: .waiting
        ))
    }

    func setDownloadStatus(_ id: UUID, _ status: PendingDownload.Status) {
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[idx].status = status
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.status == .done || $0.status == .failed }
    }

    // MARK: - Chat

    func sendMessage(_ text: String, attachment: Attachment? = nil, to contact: Contact) {
        let msg = ChatMessage(id: UUID(), fromID: config.myID, fromName: config.myName,
                              text: text, date: Date(), delivered: false,
                              channelID: nil, attachment: attachment)
        chats[contact.id, default: []].append(msg)
    }

    /// Message de groupe : une seule identité de message, déposée dans chaque
    /// conversation (la vue groupe dédoublonne par id).
    func broadcast(_ text: String, attachment: Attachment? = nil) {
        let msg = ChatMessage(id: UUID(), fromID: config.myID, fromName: config.myName,
                              text: text, date: Date(), delivered: false,
                              channelID: nil, attachment: attachment)
        for contact in contacts {
            chats[contact.id, default: []].append(msg)
        }
    }

    /// Message de canal : déposé dans la conversation de chaque membre,
    /// avec le même id (la vue canal dédoublonne).
    func sendChannelMessage(_ text: String, attachment: Attachment? = nil, in channel: Channel) {
        let msg = ChatMessage(id: UUID(), fromID: config.myID, fromName: config.myName,
                              text: text, date: Date(), delivered: false,
                              channelID: channel.id, attachment: attachment)
        for contact in contacts where channel.memberIDs.contains(contact.id) {
            chats[contact.id, default: []].append(msg)
        }
    }

    /// Tous les messages d'un canal (toutes conversations confondues, dédoublonnés).
    func messages(in channel: Channel) -> [ChatMessage] {
        var seen = Set<UUID>()
        return chats.values.flatMap { $0 }
            .filter { $0.channelID == channel.id }
            .sorted { $0.date < $1.date }
            .filter { seen.insert($0.id).inserted }
    }

    /// Intègre les définitions de canaux reçues d'un contact :
    /// création, mise à jour des membres, et retrait (si le créateur ne nous
    /// envoie plus un de ses canaux, c'est qu'on en a été retiré ou qu'il est supprimé).
    func ingestChannels(_ incoming: [Channel], from contact: Contact) {
        for channel in incoming {
            if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                if channels[idx] != channel { channels[idx] = channel }
            } else {
                channels.append(channel)
                Notifier.notify(title: "Nouveau canal",
                                body: "Tu as été ajouté au canal #\(channel.name)")
            }
        }
        let incomingIDs = Set(incoming.map(\.id))
        let removed = channels.filter { $0.createdBy == contact.id && !incomingIDs.contains($0.id) }
        for channel in removed {
            Notifier.notify(title: "Canal retiré",
                            body: "Tu n'as plus accès au canal #\(channel.name)")
        }
        channels.removeAll { $0.createdBy == contact.id && !incomingIDs.contains($0.id) }
    }

    /// Modifie les membres d'un canal (réservé au créateur : sa version fait foi
    /// chez les membres à la prochaine synchro).
    func updateChannelMembers(_ channelID: UUID, memberIDs: [UUID]) {
        guard let idx = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[idx].memberIDs = memberIDs
    }

    /// Copie un fichier déposé dans le chat vers le dossier partagé
    /// (sous Chat/<canal ou contact>/) et retourne la pièce jointe à envoyer.
    func importChatFile(_ url: URL, scopeName: String) -> Attachment? {
        guard let shared = sharedFolderURL else { return nil }
        let fm = FileManager.default
        let safeScope = scopeName.replacingOccurrences(of: "/", with: "-")
        let destDir = shared.appendingPathComponent("Chat").appendingPathComponent(safeScope)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = url.pathExtension
        var name = url.lastPathComponent
        var dest = destDir.appendingPathComponent(name)
        var counter = 1
        while fm.fileExists(atPath: dest.path) {
            name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            dest = destDir.appendingPathComponent(name)
            counter += 1
        }
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Attachment(fileName: name, relPath: "Chat/\(safeScope)/\(name)", size: size)
    }

    /// Intègre les messages reçus via le manifest du contact (dédoublonnés par id).
    func ingestMessages(_ messages: [ChatMessage], from contact: Contact) {
        var thread = chats[contact.id] ?? []
        let known = Set(thread.map(\.id))
        let fresh = messages.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        thread.append(contentsOf: fresh)
        thread.sort { $0.date < $1.date }
        chats[contact.id] = thread
        for msg in fresh { notifyMessage(msg) }
    }

    /// Notification d'un message entrant, avec le contexte (canal, pièce jointe).
    func notifyMessage(_ msg: ChatMessage) {
        var title = "Message de \(msg.fromName)"
        if let channelID = msg.channelID,
           let channel = channels.first(where: { $0.id == channelID }) {
            title = "#\(channel.name) — \(msg.fromName)"
        }
        var body = msg.text
        if let attachment = msg.attachment {
            body = body.isEmpty ? "📎 \(attachment.fileName)" : "📎 \(attachment.fileName) — \(body)"
        }
        Notifier.notify(title: title, body: body)
    }

    /// Le contact confirme avoir reçu ces messages : on arrête de les renvoyer.
    func applyAcks(_ ids: [UUID], for contact: Contact) {
        guard var thread = chats[contact.id] else { return }
        let ackSet = Set(ids)
        var changed = false
        for i in thread.indices
        where thread[i].fromID == config.myID && !thread[i].delivered && ackSet.contains(thread[i].id) {
            thread[i].delivered = true
            changed = true
        }
        if changed { chats[contact.id] = thread }
    }

    /// Mes messages pas encore confirmés par ce contact : embarqués dans chaque manifest.
    func outbox(for contact: Contact) -> [ChatMessage] {
        (chats[contact.id] ?? []).filter { $0.fromID == config.myID && !$0.delivered }
    }

    /// Ids des derniers messages reçus de ce contact, renvoyés comme accusés.
    func receivedIDs(for contact: Contact) -> [UUID] {
        (chats[contact.id] ?? []).filter { $0.fromID != config.myID }.suffix(200).map(\.id)
    }

    // MARK: - Dossiers

    var sharedFolderURL: URL? {
        config.sharedFolder.map { URL(fileURLWithPath: $0) }
    }

    /// Racine du « dossier cloud » local : un sous-dossier par contact,
    /// contenant fichiers téléchargés et fichiers d'attente (.croc).
    var mirrorRootURL: URL {
        config.downloadFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CrocShare")
    }

    func downloadFolderURL(for contact: Contact) -> URL {
        mirrorRootURL.appendingPathComponent(contact.name)
    }

    /// Scanne le dossier partagé et construit la liste à publier à un contact,
    /// avec ses messages de chat en attente et nos accusés de réception.
    func buildLocalManifest(for contact: Contact? = nil) -> Manifest {
        var files: [RemoteFile] = []
        if let root = sharedFolderURL,
           let enumerator = FileManager.default.enumerator(
               at: root,
               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ), values.isRegularFile == true else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                files.append(RemoteFile(
                    path: rel,
                    size: Int64(values.fileSize ?? 0),
                    mtime: values.contentModificationDate ?? Date()
                ))
            }
        }
        files.sort { $0.path < $1.path }
        var manifest = Manifest(senderID: config.myID, senderName: config.myName,
                                files: files, generatedAt: Date())
        if let contact {
            manifest.messages = outbox(for: contact)
            manifest.ackIDs = receivedIDs(for: contact)
            manifest.channels = channels.filter { $0.memberIDs.contains(contact.id) }
        }
        return manifest
    }
}

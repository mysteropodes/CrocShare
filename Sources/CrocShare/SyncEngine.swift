import Foundation
import Combine

/// Moteur de synchronisation : pour chaque contact, quatre boucles concurrentes.
///
/// 1. `offerLoop`    — publie en continu notre liste de fichiers (croc send du manifest).
/// 2. `pollLoop`     — récupère le manifest du contact ; un succès = contact en ligne.
/// 3. `serveLoop`    — écoute les demandes du contact et lui envoie les fichiers demandés.
/// 4. `queueLoop`    — traite notre file d'attente dès que le contact est en ligne.
///
/// Tous les codes croc sont dérivés du secret partagé (voir Channels), donc
/// aucune clé n'est jamais saisie ni échangée après l'appairage initial.
@MainActor
final class SyncEngine: ObservableObject {
    private let store: AppStore
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancellable: AnyCancellable?

    init(store: AppStore) {
        self.store = store
    }

    func start() {
        rebuild()
        cancellable = store.$contacts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        for contact in store.contacts {
            // Le contact fictif ne parle pas à croc : il est simulé localement.
            if contact.id == AppStore.debugContactID {
                spawn("debug-\(contact.id)") { [weak self] in await self?.debugLoop() }
                continue
            }
            spawn("offer-\(contact.id)") { [weak self] in await self?.offerLoop(contact) }
            spawn("poll-\(contact.id)") { [weak self] in await self?.pollLoop(contact) }
            spawn("serve-\(contact.id)") { [weak self] in await self?.serveLoop(contact) }
            spawn("queue-\(contact.id)") { [weak self] in await self?.queueLoop(contact) }
            spawn("chat-out-\(contact.id)") { [weak self] in await self?.chatOfferLoop(contact) }
            spawn("chat-in-\(contact.id)") { [weak self] in await self?.chatPollLoop(contact) }
        }
    }

    private func spawn(_ key: String, _ body: @escaping () async -> Void) {
        tasks[key] = Task { await body() }
    }

    private func debugLoop() async {
        while !Task.isCancelled {
            store.debugTick()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrocShare").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. Publication de notre liste

    private func offerLoop(_ contact: Contact) async {
        let code = Channels.manifest(secret: contact.secret,
                                     from: store.config.myID, to: contact.id)
        while !Task.isCancelled {
            guard store.config.sharedFolder != nil, store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let manifest = store.buildLocalManifest(for: contact)
            let dir = tempDir("manifest-out-\(contact.id)")
            let file = dir.appendingPathComponent("crocshare-manifest.json")
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: file)
                let result = await CrocService.send(code: code, paths: [file.path], timeout: 45)
                store.logSync(contact.name, "envoi liste →", result)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - 2. Récupération de la liste du contact (= présence)

    private func pollLoop(_ contact: Contact) async {
        let code = Channels.manifest(secret: contact.secret,
                                     from: contact.id, to: store.config.myID)
        while !Task.isCancelled {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let dir = tempDir("manifest-in-\(contact.id)")
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 35)
            store.logSync(contact.name, "réception liste ←", result)
            if result.ok {
                let file = dir.appendingPathComponent("crocshare-manifest.json")
                if let data = try? Data(contentsOf: file),
                   let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                    let wasOnline = store.isOnline(contact)
                    store.manifests[contact.id] = manifest
                    store.markSeen(contact.id)
                    PlaceholderManager.sync(contact: contact, manifest: manifest,
                                            root: store.downloadFolderURL(for: contact))
                    if let messages = manifest.messages, !messages.isEmpty {
                        store.ingestMessages(messages, from: contact)
                    }
                    if let acks = manifest.ackIDs, !acks.isEmpty {
                        store.applyAcks(acks, for: contact)
                    }
                    // Liste vide ≠ absente : vide signifie « plus aucun canal pour toi »
                    // et déclenche le retrait des canaux de ce créateur.
                    if let channels = manifest.channels {
                        store.ingestChannels(channels, from: contact)
                    }
                    if !wasOnline {
                        Notifier.notify(title: "CrocShare",
                                        body: "\(contact.name) est en ligne")
                    }
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - 2 bis. Chat réactif (canal dédié)

    /// Envoie immédiatement les messages en attente et les suppressions :
    /// latence de quelques secondes quand les deux sont en ligne, au lieu
    /// du cycle complet des listes. Le succès croc vaut accusé de livraison.
    private func chatOfferLoop(_ contact: Contact) async {
        let code = Channels.chat(secret: contact.secret,
                                 from: store.config.myID, to: contact.id)
        while !Task.isCancelled {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let payload = ChatPayload(
                messages: store.outbox(for: contact),
                deleteIDs: store.pendingDeletes[contact.id] ?? []
            )
            guard !payload.messages.isEmpty || !payload.deleteIDs.isEmpty else {
                try? await Task.sleep(for: .seconds(2)); continue
            }
            let dir = tempDir("chat-out-\(contact.id)")
            let file = dir.appendingPathComponent("crocshare-chat.json")
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: file)
                let result = await CrocService.send(code: code, paths: [file.path], timeout: 30)
                store.logSync(contact.name, "envoi chat →", result)
                if result.ok {
                    store.markDelivered(payload.messages.map(\.id), for: contact)
                    store.clearPendingDeletes(payload.deleteIDs, for: contact)
                    store.markSeen(contact.id)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func chatPollLoop(_ contact: Contact) async {
        let code = Channels.chat(secret: contact.secret,
                                 from: contact.id, to: store.config.myID)
        while !Task.isCancelled {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let dir = tempDir("chat-in-\(contact.id)")
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 30)
            if result.ok {
                let file = dir.appendingPathComponent("crocshare-chat.json")
                if let data = try? Data(contentsOf: file),
                   let payload = try? JSONDecoder().decode(ChatPayload.self, from: data) {
                    store.ingestMessages(payload.messages, from: contact)
                    store.applyRemoteDeletes(payload.deleteIDs, from: contact)
                    store.markSeen(contact.id)
                }
                try? FileManager.default.removeItem(at: file)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - 3. Servir les demandes du contact

    private func serveLoop(_ contact: Contact) async {
        let code = Channels.request(secret: contact.secret,
                                    from: contact.id, to: store.config.myID)
        while !Task.isCancelled {
            guard store.crocPath != nil, let shared = store.sharedFolderURL else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let dir = tempDir("request-in-\(contact.id)")
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 35)
            if result.ok, let request = readRequest(in: dir) {
                // Résolution sécurisée : on refuse tout chemin sortant du dossier partagé.
                let paths = request.paths.compactMap { rel -> String? in
                    let full = shared.appendingPathComponent(rel).standardizedFileURL
                    guard full.path.hasPrefix(shared.standardizedFileURL.path + "/")
                        || full.path == shared.standardizedFileURL.path else { return nil }
                    guard FileManager.default.fileExists(atPath: full.path) else { return nil }
                    return full.path
                }
                if !paths.isEmpty {
                    let filesCode = Channels.files(secret: contact.secret,
                                                   requestID: request.requestID)
                    let sent = await CrocService.send(code: filesCode, paths: paths, timeout: 3600)
                    store.logSync(contact.name, "envoi fichiers →", sent)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func readRequest(in dir: URL) -> FileRequest? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.lastPathComponent.hasPrefix("crocshare-request") {
            defer { try? FileManager.default.removeItem(at: url) }
            if let data = try? Data(contentsOf: url),
               let req = try? JSONDecoder().decode(FileRequest.self, from: data) {
                return req
            }
        }
        return nil
    }

    // MARK: - 4. File d'attente de nos téléchargements

    private func queueLoop(_ contact: Contact) async {
        while !Task.isCancelled {
            let waiting = store.downloads.filter {
                $0.contactID == contact.id && $0.status == .waiting
            }
            if !waiting.isEmpty, store.isOnline(contact), store.crocPath != nil {
                for item in waiting where !Task.isCancelled {
                    await download(item, from: contact)
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func download(_ item: PendingDownload, from contact: Contact) async {
        store.setDownloadStatus(item.id, .transferring)

        let request = FileRequest(requestID: UUID().uuidString, paths: [item.filePath])
        let dir = tempDir("request-out-\(contact.id)")
        let reqFile = dir.appendingPathComponent("crocshare-request-\(request.requestID).json")
        guard let data = try? JSONEncoder().encode(request) else {
            store.setDownloadStatus(item.id, .failed); return
        }
        try? data.write(to: reqFile)

        let reqCode = Channels.request(secret: contact.secret,
                                       from: store.config.myID, to: contact.id)
        let sent = await CrocService.send(code: reqCode, paths: [reqFile.path], timeout: 40)
        store.logSync(contact.name, "demande fichier →", sent)
        try? FileManager.default.removeItem(at: reqFile)
        guard sent.ok else {
            // Le contact n'a pas pris la requête : on repasse en attente, on réessaiera.
            store.setDownloadStatus(item.id, .waiting)
            return
        }

        // Réception dans un dossier temporaire, puis déplacement à l'emplacement
        // exact dans le dossier cloud (croc dépose les fichiers à plat).
        let tmpOut = tempDir("download-\(request.requestID)")
        let filesCode = Channels.files(secret: contact.secret, requestID: request.requestID)
        let received = await CrocService.receive(code: filesCode, outDir: tmpOut, timeout: 3600)
        store.logSync(contact.name, "réception fichier ←", received)

        if received.ok {
            let fm = FileManager.default
            let root = store.downloadFolderURL(for: contact)
            let dest = root.appendingPathComponent(item.filePath)
            let src = tmpOut.appendingPathComponent((item.filePath as NSString).lastPathComponent)
            if fm.fileExists(atPath: src.path) {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: src, to: dest)
                PlaceholderManager.removeStub(for: item.filePath, root: root)
            }
            store.setDownloadStatus(item.id, .done)
            Notifier.notify(
                title: "Téléchargement terminé",
                body: "\((item.filePath as NSString).lastPathComponent) reçu de \(contact.name)"
            )
        } else {
            store.setDownloadStatus(item.id, .waiting)
        }
    }
}

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
    private var cancellables = Set<AnyCancellable>()

    init(store: AppStore) {
        self.store = store
    }

    func start() {
        rebuild()
        store.$contacts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        store.$pendingInvites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        store.$pendingInviteAcks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
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
        // Invitations asynchrones : l'hôte attend l'accusé, l'invité le délivre.
        for invite in store.pendingInvites {
            spawn("invite-\(invite.id)") { [weak self] in await self?.inviteWaitLoop(invite) }
        }
        for ack in store.pendingInviteAcks {
            spawn("inviteack-\(ack.id)") { [weak self] in await self?.inviteAckLoop(ack) }
        }
    }

    // MARK: - Invitations asynchrones

    private func inviteWaitLoop(_ invite: PendingInvite) async {
        let code = Channels.code(secret: invite.secret,
                                 label: "inviteack:\(invite.id.uuidString)")
        while !Task.isCancelled,
              store.pendingInvites.contains(where: { $0.id == invite.id }) {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let dir = tempDir("invite-\(invite.id)")
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 300)
            if result.ok,
               let data = try? Data(contentsOf: dir.appendingPathComponent("crocshare-pairing.json")),
               let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) {
                store.completeInvite(invite, payload: payload)
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func inviteAckLoop(_ ack: PendingInviteAck) async {
        let code = Channels.code(secret: ack.secret,
                                 label: "inviteack:\(ack.id.uuidString)")
        while !Task.isCancelled,
              store.pendingInviteAcks.contains(where: { $0.id == ack.id }) {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let payload = PairingPayload(id: store.config.myID,
                                         name: store.config.myName, secret: nil)
            let dir = tempDir("inviteack-\(ack.id)")
            let file = dir.appendingPathComponent("crocshare-pairing.json")
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: file)
                let result = await CrocService.send(code: code, paths: [file.path], timeout: 60)
                if result.ok {
                    store.pendingInviteAcks.removeAll { $0.id == ack.id }
                    return
                }
            }
            try? await Task.sleep(for: .seconds(30))
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
            // Timeout long : tuer/relancer un récepteur laisse un fantôme dans la
            // salle relai qui fait échouer l'émetteur suivant. Moins de kills,
            // moins de fantômes — un récepteur qui attend ne coûte rien.
            let dir = tempDir("manifest-in-\(contact.id)")
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 120)
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
                    if let rooms = manifest.rooms {
                        store.ingestRooms(rooms, from: contact)
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
        // Backoff après échec : marteler une salle relai toutes les 2 s laisse
        // des connexions à moitié mortes qui font échouer les tentatives suivantes.
        var backoff: Double = 2
        while !Task.isCancelled {
            guard store.crocPath != nil else {
                try? await Task.sleep(for: .seconds(10)); continue
            }
            let payload = ChatPayload(
                messages: store.outbox(for: contact),
                deleteIDs: store.pendingDeletes[contact.id] ?? []
            )
            guard !payload.messages.isEmpty || !payload.deleteIDs.isEmpty else {
                backoff = 2
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
                    backoff = 2
                } else {
                    backoff = min(backoff * 2, 30)
                }
            }
            try? await Task.sleep(for: .seconds(backoff))
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
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 180)
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
            try? await Task.sleep(for: .seconds(3))
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
            let result = await CrocService.receive(code: code, outDir: dir, timeout: 300)
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
                    // stallTimeout : si le demandeur ne se connecte pas (ou décroche),
                    // on libère la boucle au lieu de rester bloqué 1 h sur une salle morte.
                    let sent = await CrocService.send(code: filesCode, paths: paths,
                                                      timeout: 24 * 3600, stallTimeout: 180)
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
        var backoff: Double = 5
        while !Task.isCancelled {
            let waiting = store.downloads.filter {
                $0.contactID == contact.id && $0.status == .waiting
            }
            if !waiting.isEmpty, store.isOnline(contact), store.crocPath != nil {
                var anySuccess = false
                for item in waiting where !Task.isCancelled {
                    await download(item, from: contact)
                    if store.downloads.first(where: { $0.id == item.id })?.status == .done {
                        anySuccess = true
                    }
                }
                // Échec complet : on espace les tentatives pour laisser le relai respirer.
                backoff = anySuccess ? 5 : min(backoff * 2, 60)
            } else {
                backoff = 5
            }
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    private func download(_ item: PendingDownload, from contact: Contact) async {
        store.setDownloadStatus(item.id, .transferring)

        // Cycle complet demande → réception, réessayé en entier : après un
        // échec de connexion, l'envoyeur en face est mort, il faut re-demander.
        var received = CrocResult(exitCode: -1, output: "", timedOut: false)
        var tmpOut = FileManager.default.temporaryDirectory
        var requestID = ""

        for attempt in 1...3 where !Task.isCancelled && !received.ok {
            if attempt > 1 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }

            let request = FileRequest(requestID: UUID().uuidString, paths: [item.filePath])
            requestID = request.requestID
            let dir = tempDir("request-out-\(contact.id)")
            let reqFile = dir.appendingPathComponent("crocshare-request-\(requestID).json")
            guard let data = try? JSONEncoder().encode(request) else { break }
            try? data.write(to: reqFile)

            let reqCode = Channels.request(secret: contact.secret,
                                           from: store.config.myID, to: contact.id)
            let sent = await CrocService.send(code: reqCode, paths: [reqFile.path], timeout: 40)
            store.logSync(contact.name, "demande fichier → (essai \(attempt))", sent)
            try? FileManager.default.removeItem(at: reqFile)
            guard sent.ok else { continue }

            // Le serveur en face met 1-3 s à ouvrir la salle de livraison
            // (latence réseau) : se connecter trop tôt = « room not ready ».
            try? await Task.sleep(for: .seconds(3))

            // Réception dans un dossier temporaire, puis déplacement à l'emplacement
            // exact dans le dossier cloud (croc dépose les fichiers à plat).
            // Le sender attend jusqu'à 3 min : une connexion ratée se rattrape
            // en retentant la MÊME salle avant de refaire une demande complète.
            tmpOut = tempDir("download-\(requestID)")
            let filesCode = Channels.files(secret: contact.secret, requestID: requestID)
            for subAttempt in 1...3 where !received.ok && !Task.isCancelled {
                received = await CrocService.receive(code: filesCode, outDir: tmpOut,
                                                     timeout: 24 * 3600, stallTimeout: 180)
                store.logSync(contact.name,
                              "réception fichier ← (essai \(attempt).\(subAttempt))", received)
                if !received.ok { try? await Task.sleep(for: .seconds(3)) }
            }
        }

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

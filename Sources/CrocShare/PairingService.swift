import Foundation

/// Appairage automatique des clés entre deux contacts, via croc lui-même.
///
/// Côté hôte : génère un code lisible + un secret, et publie le secret sur ce code.
/// Côté invité : saisit le code, reçoit le secret, renvoie son identité en accusé.
/// Après ça, plus aucune clé à gérer : tout est dérivé du secret partagé.
@MainActor
final class PairingService: ObservableObject {
    enum State: Equatable {
        case idle
        case hosting(code: String)
        case joining
        case success(contactName: String)
        case failed(String)
    }

    @Published var state: State = .idle
    private let store: AppStore
    private var task: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrocShare/pairing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Côté hôte : affiche un code, attend que l'invité le saisisse (5 min max).
    func host() {
        let code = Channels.newPairingCode()
        let secret = Channels.newSecret()
        state = .hosting(code: code)
        let payload = PairingPayload(id: store.config.myID, name: store.config.myName, secret: secret)

        task = Task {
            let dir = tempDir()
            let file = dir.appendingPathComponent("crocshare-pairing.json")
            guard let data = try? JSONEncoder().encode(payload) else {
                state = .failed("Erreur interne d'encodage"); return
            }
            try? data.write(to: file)

            let sent = await CrocService.send(code: code, paths: [file.path], timeout: 300)
            guard sent.ok, !Task.isCancelled else {
                if !Task.isCancelled {
                    state = .failed(sent.timedOut
                        ? "Personne n'a saisi le code dans les 5 minutes. Régénère un code et réessaie."
                        : "Erreur croc : \(sent.lastLine)")
                }
                return
            }

            // L'invité renvoie son identité sur <code>ak (sans tiret : salle unique).
            let ackDir = tempDir()
            let gotAck = await CrocService.receive(code: code + "ak", outDir: ackDir, timeout: 120)
            guard gotAck.ok,
                  let ackData = try? Data(contentsOf: ackDir.appendingPathComponent("crocshare-pairing.json")),
                  let peer = try? JSONDecoder().decode(PairingPayload.self, from: ackData),
                  !Task.isCancelled
            else {
                if !Task.isCancelled { state = .failed("Le contact a reçu le code mais n'a pas confirmé. Réessayez tous les deux.") }
                return
            }

            store.contacts.append(Contact(id: peer.id, name: peer.name, secret: secret))
            state = .success(contactName: peer.name)
        }
    }

    /// Côté invité : saisit le code affiché chez l'hôte.
    func join(code: String) {
        // Normalisation : espaces et tirets retirés (les codes n'en contiennent plus).
        let code = code.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !code.isEmpty else { return }
        state = .joining

        task = Task {
            let dir = tempDir()
            let ok = await CrocService.receive(code: code, outDir: dir, timeout: 90)
            guard ok.ok,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("crocshare-pairing.json")),
                  let peer = try? JSONDecoder().decode(PairingPayload.self, from: data),
                  let secret = peer.secret,
                  !Task.isCancelled
            else {
                if !Task.isCancelled { state = .failed("Code invalide ou hôte indisponible") }
                return
            }

            let me = PairingPayload(id: store.config.myID, name: store.config.myName, secret: nil)
            let ackDir = tempDir()
            let ackFile = ackDir.appendingPathComponent("crocshare-pairing.json")
            if let ackData = try? JSONEncoder().encode(me) {
                try? ackData.write(to: ackFile)
                _ = await CrocService.send(code: code + "ak", paths: [ackFile.path], timeout: 120)
            }

            store.contacts.append(Contact(id: peer.id, name: peer.name, secret: secret))
            state = .success(contactName: peer.name)
        }
    }
}

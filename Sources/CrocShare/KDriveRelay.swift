import Foundation
import CryptoKit
import os

// ─────────────────────────────────────────────────────────────────────────────
// MODULE  KDriveRelay
//
// Relai store-and-forward optionnel sur Infomaniak kDrive : quand un contact
// est hors ligne, on dépose le message chiffré (AES-GCM) dans un dossier
// kDrive ; le destinataire le récupère au prochain démarrage et le supprime
// immédiatement.
//
// ── Choix d'architecture ───────────────────────────────────────────────────
// • « Compte kDrive partagé » : un seul compte Infomaniak héberge le relai
//   pour tous les contacts. Aucun secret n'est codé en dur : l'admin colle
//   un Personal Access Token (PAT) dans Réglages → Trousseau macOS.
// • Le PAT est révocable à tout chaud depuis manager.infomaniak.com.
// • Pour migrer vers un proxy serveur, ne change que `KDriveAPI.baseURL`
//   et le header d'auth — le reste du module reste identique.
//
// ── Comment obtenir un PAT Infomaniak ──────────────────────────────────────
// 1. https://manager.infomaniak.com → ton compte → « API et applications »
// 2. « Créer un token »
// 3. Scope minimum : `drive` (lecture/écriture sur kDrive)
// 4. Note l'ID du Drive (visible dans l'URL https://kdrive.infomaniak.com/app/drive/<DRIVE_ID>/)
// 5. Crée à la racine du Drive un dossier `crocshare-relay` et note son ID
//    (URL : .../files/<FOLDER_ID>). Ce dossier servira de boîte commune.
// 6. Colle PAT + driveID + folderID dans Réglages CrocShare → Relai kDrive.
//
// ── Sécurité ───────────────────────────────────────────────────────────────
// • Le PAT vit dans le Trousseau macOS, jamais en clair sur disque.
// • Le payload est chiffré côté client (AES-GCM 256). Le relai ne voit qu'un
//   blob opaque + métadonnées de routage (from/to en hash 8 chars).
// • Clé de chiffrement par paire : dérivée HKDF du shared-secret négocié
//   pendant le pairing P2P (cf. `P2PEngine.relayKey(for:)`). Si la paire n'a
//   jamais été en ligne ensemble, le relai ne peut pas être utilisé pour eux.
// ─────────────────────────────────────────────────────────────────────────────

private let log = Logger(subsystem: "com.crocshare.app", category: "KDriveRelay")

// MARK: - Configuration

/// Réglages utilisateur du relai. Tout sauf le PAT est stocké dans `AppStore.config`.
/// Le PAT vit dans le Trousseau et n'est jamais sérialisé.
public struct KDriveRelayConfig: Codable, Equatable {
    public var enabled: Bool = false
    public var driveID: String = ""          // ex: "123456"
    public var folderID: String = ""         // ID du dossier racine /crocshare-relay
    public var pollSeconds: Int = 45         // intervalle de poll inbox
    public var maxAgeSeconds: Int = 7 * 24 * 3600  // purge auto > 7j
    public init() {}
}

// MARK: - Modèle de message relayé

/// Enveloppe écrite sur kDrive. Le champ `blob` contient le payload chiffré
/// (base64). Les champs `from`/`to` sont des short-keys (8 hex) pour le routage
/// uniquement : ils ne révèlent pas l'identité au-delà de ce que le pairing
/// expose déjà.
public struct RelayEnvelope: Codable {
    public let version: Int          // = 1
    public let from: String          // short-key (8 hex)
    public let to: String            // short-key (8 hex)
    public let messageID: String     // UUID du P2PMessage d'origine
    public let timestamp: Int        // ms epoch
    public let nonce: String         // base64 AES-GCM nonce
    public let blob: String          // base64 AES-GCM ciphertext + tag
}

// MARK: - Stockage PAT (Keychain)

enum KDriveTokenStore {
    static let service = "com.crocshare.app.kdrive-pat"
    static let account = "pat"

    static func save(_ pat: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: Data(pat.utf8)]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery; add[kSecValueData as String] = Data(pat.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Crypto (AES-GCM 256 par paire)

enum RelayCrypto {
    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> (nonce: Data, blob: Data) {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return (sealed.nonce.withUnsafeBytes { Data($0) }, sealed.ciphertext + sealed.tag)
    }

    static func decrypt(blob: Data, nonce: Data, key: SymmetricKey) throws -> Data {
        // Le tag GCM fait 16 octets : il est suffixé au ciphertext.
        guard blob.count > 16 else { throw RelayError.cryptoFailed }
        let ct = blob.dropLast(16)
        let tag = blob.suffix(16)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
        return try AES.GCM.open(sealed, using: key)
    }

    /// Dérive une clé déterministe à partir d'un secret partagé brut + tag de contexte.
    /// Permet de séparer les clés "relai" d'autres usages futurs sans risque de
    /// cross-protocol.
    static func derive(sharedSecret: Data, contextTag: String = "crocshare-relay-v1") -> SymmetricKey {
        let salt = Data(contextTag.utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret),
                                       salt: salt, outputByteCount: 32)
    }
}

// MARK: - Erreurs

public enum RelayError: Error, LocalizedError {
    case notConfigured
    case noPAT
    case http(Int, String)
    case decode
    case cryptoFailed
    case missingPairKey(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Relai kDrive non configuré (drive ID / folder ID manquant)."
        case .noPAT: return "Token kDrive absent du trousseau."
        case .http(let code, let body): return "kDrive HTTP \(code): \(body.prefix(200))"
        case .decode: return "Réponse kDrive illisible."
        case .cryptoFailed: return "Déchiffrement impossible (clé incorrecte ou blob altéré)."
        case .missingPairKey(let k): return "Aucune clé de relai partagée pour \(k.prefix(8))… : appairez-vous d'abord en P2P."
        }
    }
}

// MARK: - Client HTTP kDrive

/// Couche transport. Tout passe par `request`, qui gère retry+backoff sur
/// erreurs réseau et 429/5xx. Le PAT est lu à chaque appel depuis le Trousseau
/// (révocation immédiate possible).
struct KDriveAPI {
    var baseURL = URL(string: "https://api.infomaniak.com")!
    var session: URLSession = .shared
    var debug = false

    private func authedRequest(_ url: URL, method: String, body: Data? = nil, contentType: String? = nil) throws -> URLRequest {
        guard let pat = KDriveTokenStore.load(), !pat.isEmpty else { throw RelayError.noPAT }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        req.timeoutInterval = 30
        return req
    }

    /// Exécute une requête avec retry exponentiel sur 429/5xx + erreurs réseau.
    /// Max 4 tentatives (≈ 0 + 1 + 2 + 4 s + jitter).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastError: Error?
        while attempt < 4 {
            do {
                let (data, resp) = try await session.data(for: request)
                guard let http = resp as? HTTPURLResponse else { throw RelayError.decode }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                // 429 : respecter Retry-After si fourni.
                if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Double($0) }
                    let backoff = retryAfter ?? (pow(2.0, Double(attempt)) + Double.random(in: 0...0.5))
                    if debug { log.debug("relay backoff \(backoff)s after HTTP \(http.statusCode)") }
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                    continue
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                throw RelayError.http(http.statusCode, text)
            } catch let e as RelayError {
                throw e
            } catch {
                lastError = error
                let backoff = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
                if debug { log.debug("relay net err \(error.localizedDescription), backoff \(backoff)s") }
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                attempt += 1
            }
        }
        throw lastError ?? RelayError.http(0, "épuisé après 4 tentatives")
    }

    // MARK: API kDrive

    /// Upload un fichier dans le dossier folderID. Le nom est imposé pour éviter
    /// les collisions : `{ts}_{messageID}.json`.
    func upload(driveID: String, folderID: String, name: String, body: Data) async throws -> String {
        // https://developer.infomaniak.com/docs/api/post/3/drive/{drive_id}/upload
        var comps = URLComponents(url: baseURL.appendingPathComponent("/3/drive/\(driveID)/upload"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "directory_id", value: folderID),
            URLQueryItem(name: "total_size", value: String(body.count)),
            URLQueryItem(name: "file_name", value: name),
            URLQueryItem(name: "conflict", value: "rename"),
        ]
        let req = try authedRequest(comps.url!, method: "POST", body: body, contentType: "application/octet-stream")
        let (data, _) = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["data"] as? [String: Any],
              let id = result["id"] as? Int ?? (result["id"] as? Int64).map(Int.init) else {
            throw RelayError.decode
        }
        return String(id)
    }

    struct ListedFile { let id: String; let name: String; let createdAt: Date }

    func list(driveID: String, folderID: String) async throws -> [ListedFile] {
        let url = baseURL.appendingPathComponent("/3/drive/\(driveID)/files/\(folderID)/files")
        let req = try authedRequest(url, method: "GET")
        let (data, _) = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { throw RelayError.decode }
        return items.compactMap { item in
            let id: String? = (item["id"] as? Int).map(String.init) ?? (item["id"] as? String)
            guard let id, let name = item["name"] as? String else { return nil }
            let created = (item["created_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            return ListedFile(id: id, name: name, createdAt: created)
        }
    }

    func download(driveID: String, fileID: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("/2/drive/\(driveID)/files/\(fileID)/download")
        let req = try authedRequest(url, method: "GET")
        let (data, _) = try await send(req)
        return data
    }

    func delete(driveID: String, fileID: String) async throws {
        let url = baseURL.appendingPathComponent("/3/drive/\(driveID)/files/\(fileID)")
        let req = try authedRequest(url, method: "DELETE")
        _ = try await send(req)
    }

    /// Ping léger pour le bouton « Tester la connexion ».
    func ping(driveID: String) async throws {
        let url = baseURL.appendingPathComponent("/2/drive/\(driveID)")
        let req = try authedRequest(url, method: "GET")
        _ = try await send(req)
    }
}

// MARK: - Source des clés de paire

/// Le module relai ne dépend pas directement de P2PEngine ; il consomme une
/// petite abstraction. Le wiring concret se fait dans P2PEngine.
@MainActor
public protocol RelayPairKeyProvider: AnyObject {
    /// Identifiant court (8 hex) à inscrire dans l'enveloppe pour le routage.
    func shortKey(for fullKey: String) -> String
    /// Pubkey complète courante de l'utilisateur (envoyeur).
    var myPublicKey: String { get }
    /// Clé symétrique pour chiffrer/déchiffrer avec ce contact. Nil si jamais
    /// appairé en P2P : impossible d'utiliser le relai pour cette paire.
    func relayKey(for contactKey: String) -> SymmetricKey?
    /// Liste de mes contacts (pour scanner mon inbox kDrive et router au bon
    /// déchiffrement). Le routage par short-key est non sensible.
    var contactsForRelay: [String] { get }
}

// MARK: - Acteur principal

/// Orchestrateur. Toutes les opérations passent par cet acteur — pas de course
/// possible sur le polling timer.
public actor KDriveRelay {
    public static let shared = KDriveRelay()

    private var api = KDriveAPI()
    private var config = KDriveRelayConfig()
    private weak var keyProvider: RelayPairKeyProvider?
    private var pollTask: Task<Void, Never>?

    /// Callback appelé pour chaque message reçu et déchiffré. Le pipeline
    /// P2PEngine peut le réinjecter dans son flux normal.
    public var onMessageReceived: ((_ from: String, _ messageID: String, _ payload: Data) -> Void)?

    public func configure(_ cfg: KDriveRelayConfig, keyProvider: RelayPairKeyProvider, debugLogs: Bool = false) {
        self.config = cfg
        self.keyProvider = keyProvider
        self.api.debug = debugLogs
        // Redémarre le polling au cas où l'intervalle a changé.
        if cfg.enabled { startPolling() } else { stopPolling() }
    }

    public func setOnMessageReceived(_ cb: @escaping (String, String, Data) -> Void) {
        onMessageReceived = cb
    }

    public func updateEnabled(_ on: Bool) {
        config.enabled = on
        if on { startPolling() } else { stopPolling() }
    }

    // MARK: send

    /// Envoie un message au relai pour un contact donné.
    /// `payload` = bytes du P2PMessage sérialisé côté P2PEngine. À toi de
    /// décider du format (JSON, MessagePack…) — le relai est agnostique.
    public func enqueue(to contactKey: String, messageID: String, payload: Data) async throws {
        guard config.enabled else { throw RelayError.notConfigured }
        guard !config.driveID.isEmpty, !config.folderID.isEmpty else { throw RelayError.notConfigured }
        guard let provider = keyProvider else { throw RelayError.notConfigured }
        let (myKey, contactShort, mySymKey) = await MainActor.run { () -> (String, String, SymmetricKey?) in
            (provider.shortKey(for: provider.myPublicKey),
             provider.shortKey(for: contactKey),
             provider.relayKey(for: contactKey))
        }
        guard let key = mySymKey else { throw RelayError.missingPairKey(contactKey) }

        let (nonce, blob) = try RelayCrypto.encrypt(payload, key: key)
        let env = RelayEnvelope(
            version: 1,
            from: myKey,
            to: contactShort,
            messageID: messageID,
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            nonce: nonce.base64EncodedString(),
            blob: blob.base64EncodedString()
        )
        let body = try JSONEncoder().encode(env)
        let name = "\(env.timestamp)_\(messageID).json"
        let fileID = try await api.upload(driveID: config.driveID, folderID: config.folderID, name: name, body: body)
        log.info("relay enqueue → \(name, privacy: .public) (kdrive id=\(fileID, privacy: .public))")
    }

    // MARK: fetch / poll

    /// Une passe : liste l'inbox, déchiffre les messages destinés à moi,
    /// supprime à mesure (idempotence + libération d'espace).
    @discardableResult
    public func fetchOnce() async throws -> Int {
        guard config.enabled, !config.driveID.isEmpty, !config.folderID.isEmpty else { return 0 }
        guard let provider = keyProvider else { return 0 }
        let snapshot = await MainActor.run { () -> (mine: String, candidates: [(key: String, short: String, sym: SymmetricKey?)]) in
            let mine = provider.shortKey(for: provider.myPublicKey)
            let candidates = provider.contactsForRelay.map { c in
                (key: c, short: provider.shortKey(for: c), sym: provider.relayKey(for: c))
            }
            return (mine, candidates)
        }
        var delivered = 0

        let files = try await api.list(driveID: config.driveID, folderID: config.folderID)
        for f in files {
            do {
                let data = try await api.download(driveID: config.driveID, fileID: f.id)
                let env = try JSONDecoder().decode(RelayEnvelope.self, from: data)
                // Filtrage côté client : ce qui n'est pas pour moi est ignoré
                // (et NON supprimé — laisse le destinataire le récupérer).
                guard env.to == snapshot.mine else { continue }
                // Identifier l'expéditeur via la short-key : on la compare à
                // chacun de mes contacts. Une short-key collision est très
                // improbable (8 hex = 32 bits) mais on tente le décrypt sur
                // tous les candidats.
                var senderFullKey: String?
                var clear: Data?
                for c in snapshot.candidates where c.short == env.from {
                    guard let key = c.sym else { continue }
                    if let nonce = Data(base64Encoded: env.nonce),
                       let blob = Data(base64Encoded: env.blob),
                       let plain = try? RelayCrypto.decrypt(blob: blob, nonce: nonce, key: key) {
                        senderFullKey = c.key
                        clear = plain
                        break
                    }
                }
                if let sender = senderFullKey, let payload = clear {
                    onMessageReceived?(sender, env.messageID, payload)
                    try await api.delete(driveID: config.driveID, fileID: f.id)
                    delivered += 1
                } else {
                    log.warning("relay decrypt failed for file \(f.name, privacy: .public)")
                }
            } catch {
                // Un fichier corrompu / pas pour moi ne doit pas bloquer le batch.
                log.warning("relay fetch item failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if delivered > 0 { log.info("relay delivered \(delivered) message(s)") }
        return delivered
    }

    /// Démarre une boucle de polling. Backoff doublé après chaque erreur, reset
    /// au succès. L'intervalle de base vient de la config (par défaut 45 s).
    private func startPolling() {
        stopPolling()
        let base = max(15, config.pollSeconds)
        pollTask = Task { [weak self] in
            var current = base
            while !Task.isCancelled {
                do {
                    _ = try await self?.fetchOnce()
                    current = base
                } catch {
                    current = min(current * 2, 600)
                    log.warning("relay poll error, next in \(current)s: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: UInt64(current) * 1_000_000_000)
            }
        }
    }

    private func stopPolling() { pollTask?.cancel(); pollTask = nil }

    // MARK: cleanup

    /// Supprime les fichiers du dossier de relai plus vieux que `maxAgeSeconds`
    /// (par défaut 7 jours). À appeler de temps en temps (au démarrage, p.ex.).
    /// Sécurité au cas où un destinataire ne se reconnecte jamais.
    public func cleanupOldMessages() async throws {
        guard config.enabled, !config.driveID.isEmpty, !config.folderID.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(config.maxAgeSeconds))
        let files = try await api.list(driveID: config.driveID, folderID: config.folderID)
        var purged = 0
        for f in files where f.createdAt < cutoff {
            try? await api.delete(driveID: config.driveID, fileID: f.id)
            purged += 1
        }
        if purged > 0 { log.info("relay purged \(purged) stale file(s)") }
    }

    // MARK: diagnostic

    /// Test de connexion : valide PAT + driveID. N'écrit rien.
    public func testConnection() async throws {
        guard !config.driveID.isEmpty else { throw RelayError.notConfigured }
        try await api.ping(driveID: config.driveID)
    }
}

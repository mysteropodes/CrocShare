import Foundation

// Pont Swift ↔ crocshare-core (compagnon P2P, Phase 1).
// Lance et surveille le processus Node/Bare, parle le protocole JSON-RPC NDJSON
// sur stdio (§5), expose les requêtes en async/await et les événements en
// AsyncStream. Watchdog : relance le compagnon avec backoff et ré-initialise.
//
// Frontière : ce fichier ne touche jamais au réseau (c'est le Core) ; le Core
// ne touche jamais au Trousseau (c'est Swift, via la seed passée à `init`).

enum CoreError: Error, LocalizedError {
    case timeout(String)
    case rpc(code: String, message: String)
    case notRunning
    case runtimeMissing

    var errorDescription: String? {
        switch self {
        case .timeout(let m): return "Délai dépassé : \(m)"
        case .rpc(_, let m): return m
        case .notRunning: return "Compagnon P2P arrêté"
        case .runtimeMissing: return "Runtime Node introuvable (compagnon non installé)"
        }
    }
}

struct CoreEvent {
    let event: String
    let params: [String: Any]
}

/// Localise le runtime node et le dossier core/ (bundle en prod, env var en dev).
enum CorePaths {
    static func node() -> URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("runtime/node")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static func coreIndex() -> URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("core/index.js")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        if let dev = ProcessInfo.processInfo.environment["CROCSHARE_CORE_DIR"] {
            return URL(fileURLWithPath: dev).appendingPathComponent("index.js")
        }
        return nil
    }

    static var storagePath: String {
        // Calcul indépendant du MainActor (CoreBridge est un actor non isolé MainActor).
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrocShare/core").path
    }

    static var logFile: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CrocShare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("core.log")
    }
}

actor CoreBridge {
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var lineBuffer = Data()
    private var intentionalStop = false
    private var restartAttempt = 0

    // Paramètres d'init mémorisés pour la relance automatique.
    private var lastSeed: String?
    private let storagePath: String

    // Flux d'événements consommé par le moteur P2P.
    private let eventContinuation: AsyncStream<CoreEvent>.Continuation
    let events: AsyncStream<CoreEvent>

    init(storagePath: String) {
        self.storagePath = storagePath
        var cont: AsyncStream<CoreEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    var isRunning: Bool { process?.isRunning == true }

    // MARK: - Cycle de vie

    func launch() throws {
        guard let node = CorePaths.node(), let index = CorePaths.coreIndex() else {
            throw CoreError.runtimeMissing
        }
        intentionalStop = false
        let proc = Process()
        proc.executableURL = node
        proc.arguments = [index.path]

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdin = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        // stderr (logs NDJSON du Core) → fichier avec rotation simple.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            CoreBridge.appendLog(data)
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }

        try proc.run()
        process = proc
    }

    /// Démarre le compagnon et l'initialise (identité + DHT).
    func start(seed: String?) async throws -> [String: Any] {
        lastSeed = seed
        try launch()
        var params: [String: Any] = ["storagePath": storagePath]
        if let seed { params["seed"] = seed }
        let result = try await request("init", params)
        restartAttempt = 0
        return result
    }

    func stop() async {
        intentionalStop = true
        _ = try? await request("shutdown", [:], timeout: 3)
        process?.terminate()
        process = nil
    }

    private func handleExit() async {
        for (_, cont) in pending { cont.resume(throwing: CoreError.notRunning) }
        pending.removeAll()
        stdin = nil
        process = nil
        guard !intentionalStop else { return }

        // Watchdog : relance avec backoff 1s / 5s / 30s.
        let delays: [UInt64] = [1, 5, 30]
        let delay = delays[min(restartAttempt, delays.count - 1)]
        restartAttempt += 1
        eventContinuation.yield(CoreEvent(event: "core.reconnecting",
                                          params: ["inSeconds": delay]))
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        guard !intentionalStop else { return }
        do {
            try launch()
            var params: [String: Any] = ["storagePath": storagePath]
            if let lastSeed { params["seed"] = lastSeed }
            _ = try await request("init", params)
            _ = try? await request("swarm.connectAll", [:])
            restartAttempt = 0
        } catch {
            eventContinuation.yield(CoreEvent(event: "core.error",
                params: ["code": "INTERNAL", "message": "relance échouée: \(error)", "fatal": false]))
            await handleExit() // réessaie avec le backoff suivant
        }
    }

    // MARK: - RPC

    @discardableResult
    func request(_ method: String, _ params: [String: Any] = [:],
                 timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard let stdin else { throw CoreError.notRunning }
        let id = nextID; nextID += 1
        let envelope: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            throw CoreError.rpc(code: "INTERNAL", message: "encodage requête")
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try stdin.write(contentsOf: data + Data("\n".utf8))
            } catch {
                pending[id] = nil
                cont.resume(throwing: CoreError.notRunning)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pendingCont = pending.removeValue(forKey: id) {
                    pendingCont.resume(throwing: CoreError.timeout(method))
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0a) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            route(obj)
        }
    }

    private func route(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: CoreError.rpc(
                    code: err["code"] as? String ?? "INTERNAL",
                    message: err["message"] as? String ?? "erreur"))
            } else {
                cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
        } else if let event = obj["event"] as? String {
            eventContinuation.yield(CoreEvent(event: event,
                                              params: obj["params"] as? [String: Any] ?? [:]))
        }
    }

    // MARK: - Logs (rotation 5 Mo)

    private static let logQueue = DispatchQueue(label: "com.crocshare.corelog")
    private static func appendLog(_ data: Data) {
        logQueue.async {
            let url = CorePaths.logFile
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

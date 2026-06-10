import Foundation

struct CrocResult {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
    /// croc peut sortir avec le code 0 quand on le tue : un timeout n'est jamais un succès.
    var ok: Bool { exitCode == 0 && !timedOut }
    /// Dernière ligne non vide de la sortie croc, pour les messages d'erreur.
    var lastLine: String {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}

/// Enveloppe du binaire croc : envoi/réception avec timeout (croc lui-même attend indéfiniment).
enum CrocService {
    /// Relai auto-hébergé optionnel ("hôte:port"), positionné par le Store.
    /// nonisolated(unsafe) : écrit uniquement depuis le MainActor, lu par les boucles.
    nonisolated(unsafe) static var customRelay: String?

    static let candidatePaths = [
        "/opt/homebrew/bin/croc",
        "/usr/local/bin/croc",
        "/usr/bin/croc",
        NSHomeDirectory() + "/go/bin/croc",
    ]

    static func findCroc() -> String? {
        // croc embarqué dans le bundle : aucune installation requise.
        if let bundled = Bundle.main.resourcePath.map({ $0 + "/bin/croc" }),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// État partagé entre les handlers du process, protégé par verrou.
    private final class TransferState: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var killedByTimeout = false
        var collected = Data()
    }

    /// Lance croc avec un timeout dur : le process est tué s'il dépasse.
    /// Le code phrase passe par CROC_SECRET : croc 10.x refuse `--code` en CLI sur Unix.
    static func run(arguments: [String], secret: String, timeout: TimeInterval) async -> CrocResult {
        guard let croc = findCroc() else {
            return CrocResult(exitCode: -1, output: "croc introuvable", timedOut: false)
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: croc)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["CROC_NO_CHECK_UPDATE"] = "1"
            env["CROC_SECRET"] = secret
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Pas de stdin : croc ne doit jamais attendre une réponse interactive.
            process.standardInput = FileHandle.nullDevice

            let state = TransferState()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                state.lock.lock()
                state.collected.append(data)
                state.lock.unlock()
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.finished else { return }
                state.finished = true
                let out = String(data: state.collected, encoding: .utf8) ?? ""
                continuation.resume(returning: CrocResult(
                    exitCode: proc.terminationStatus, output: out,
                    timedOut: state.killedByTimeout
                ))
            }

            do {
                try process.run()
            } catch {
                state.lock.lock()
                if !state.finished {
                    state.finished = true
                    state.lock.unlock()
                    continuation.resume(returning: CrocResult(exitCode: -1, output: "\(error)", timedOut: false))
                } else {
                    state.lock.unlock()
                }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.lock.lock()
                let alreadyDone = state.finished
                if !alreadyDone { state.killedByTimeout = true }
                state.lock.unlock()
                if !alreadyDone, process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    private static var relayArgs: [String] {
        guard let relay = customRelay?.trimmingCharacters(in: .whitespaces), !relay.isEmpty else {
            return []
        }
        return ["--relay", relay]
    }

    /// Envoie des fichiers : réussit seulement si un receveur s'est connecté avant le timeout.
    static func send(code: String, paths: [String], timeout: TimeInterval) async -> CrocResult {
        await run(arguments: relayArgs + ["send"] + paths, secret: code, timeout: timeout)
    }

    /// Tente de recevoir sur un code ; échoue silencieusement si personne n'envoie.
    static func receive(code: String, outDir: URL, timeout: TimeInterval) async -> CrocResult {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return await run(
            arguments: relayArgs + ["--yes", "--overwrite", "--out", outDir.path],
            secret: code,
            timeout: timeout
        )
    }
}

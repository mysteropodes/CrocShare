import Foundation

/// Mini-serveur relai croc hébergé sur ce Mac (`croc relay`).
/// Le relai ne fait que mettre en relation : tous les flux qui le traversent
/// sont chiffrés de bout en bout, il ne peut lire ni fichiers ni clés.
/// Les contacts s'y connectent via l'IP publique / DDNS de ce Mac, port 9009
/// (ports TCP 9009-9013 à ouvrir sur la box).
@MainActor
final class RelayServer: ObservableObject {
    static let shared = RelayServer()

    static let port = 9009
    @Published var running = false
    @Published var localIP = ""
    private var process: Process?

    func start() {
        guard process == nil, let croc = CrocService.findCroc() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: croc)
        p.arguments = ["relay"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.running = false
            }
        }
        do {
            try p.run()
            process = p
            running = true
            localIP = Self.detectLocalIP()
        } catch {
            process = nil
            running = false
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        running = false
    }

    static func detectLocalIP() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getifaddr", "en0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

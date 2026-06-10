import Foundation
import AppKit

/// Gère le « dossier cloud » : pour chaque fichier distant non téléchargé,
/// un fichier d'attente `nom.ext.croc` (avec icône nuage) est posé dans
/// ~/CrocShare/<Contact>/. Double-clic dessus → l'app met le fichier en file
/// de téléchargement et le remplace par le vrai fichier une fois reçu.
enum PlaceholderManager {
    static let fileExtension = "croc"

    /// Contenu JSON d'un fichier d'attente : de quoi retrouver quoi télécharger chez qui.
    struct Stub: Codable {
        var contactID: UUID
        var path: String
        var size: Int64
    }

    /// Icône nuage apposée sur les fichiers d'attente.
    static let cloudIcon: NSImage = {
        let canvas = NSSize(width: 256, height: 256)
        let image = NSImage(size: canvas)
        image.lockFocus()
        if let symbol = NSImage(systemSymbolName: "icloud.and.arrow.down.fill",
                                accessibilityDescription: "Fichier distant"),
           let configured = symbol.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: 170, weight: .regular)
           ) {
            let rect = NSRect(x: 28, y: 48, width: 200, height: 160)
            configured.draw(in: rect)
            NSColor.systemBlue.set()
            rect.fill(using: .sourceAtop)
        }
        image.unlockFocus()
        return image
    }()

    /// Synchronise les fichiers d'attente d'un contact avec son manifest :
    /// crée ceux qui manquent, supprime ceux dont le fichier a disparu chez lui
    /// ou est déjà téléchargé localement.
    static func sync(contact: Contact, manifest: Manifest, root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let validPaths = Set(manifest.files.map { $0.path })

        for file in manifest.files {
            let real = root.appendingPathComponent(file.path)
            let stubURL = root.appendingPathComponent(file.path + "." + fileExtension)
            if fm.fileExists(atPath: real.path) {
                try? fm.removeItem(at: stubURL)
                continue
            }
            guard !fm.fileExists(atPath: stubURL.path) else { continue }
            try? fm.createDirectory(at: stubURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let stub = Stub(contactID: contact.id, path: file.path, size: file.size)
            if let data = try? JSONEncoder().encode(stub) {
                try? data.write(to: stubURL)
                NSWorkspace.shared.setIcon(cloudIcon, forFile: stubURL.path, options: [])
            }
        }

        // Purge des fichiers d'attente devenus orphelins.
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == fileExtension {
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count)
                .dropLast(fileExtension.count + 1))
            if !validPaths.contains(rel) {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func readStub(at url: URL) -> Stub? {
        guard url.pathExtension == fileExtension,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stub.self, from: data)
    }

    /// Une fois le fichier reçu, supprime son fichier d'attente.
    static func removeStub(for relPath: String, root: URL) {
        let stubURL = root.appendingPathComponent(relPath + "." + fileExtension)
        try? FileManager.default.removeItem(at: stubURL)
    }
}

import SwiftUI
import AppKit

/// Reçoit les doubles-clics sur les fichiers d'attente .croc depuis le Finder :
/// met le fichier correspondant en file de téléchargement.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: AppStore?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let store = Self.store else { return }
        for url in urls {
            // Double-clic sur un fichier d'invitation .crocinvite.
            if url.pathExtension == "crocinvite",
               let data = try? Data(contentsOf: url),
               let invite = try? JSONDecoder().decode(InviteFile.self, from: data) {
                store.importInvite(invite)
                continue
            }
            guard let stub = PlaceholderManager.readStub(at: url),
                  let contact = store.contacts.first(where: { $0.id == stub.contactID })
            else { continue }
            let file = RemoteFile(path: stub.path, size: stub.size, mtime: Date())
            store.enqueueDownload(file: file, contact: contact)
            let name = (stub.path as NSString).lastPathComponent
            if store.isOnline(contact) {
                Notifier.notify(title: "Téléchargement lancé",
                                body: "\(name) depuis \(contact.name)")
            } else {
                Notifier.notify(title: "Mis en attente",
                                body: "\(name) sera téléchargé dès que \(contact.name) sera en ligne.")
            }
        }
    }

    // L'app vit dans la barre de menus : fermer la fenêtre ne quitte pas.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Ne pas laisser le relai orphelin après la fermeture de l'app.
    func applicationWillTerminate(_ notification: Notification) {
        RelayServer.shared.stop()
    }
}

@main
struct CrocShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: AppStore
    @StateObject private var engine: SyncEngine
    @StateObject private var pairing: PairingService
    @StateObject private var p2p = P2PEngine()

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: SyncEngine(store: store))
        _pairing = StateObject(wrappedValue: PairingService(store: store))
        AppDelegate.store = store
    }

    var body: some Scene {
        Window("CrocShare", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(pairing)
                .environmentObject(p2p)
                .onAppear {
                    Notifier.requestPermission()
                    UpdateManager.shared.start()
                    // Moteur P2P (Hyperswarm) = moteur principal. croc débranché
                    // (code conservé en réserve, plus démarré).
                    p2p.enable(displayName: store.config.myName)
                    p2p.configure(sharedFolder: store.config.sharedFolder,
                                  downloadBase: store.mirrorRootURL.path)
                }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(p2p)
        } label: {
            if p2p.totalUnread > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "icloud.and.arrow.down.fill")
                    Text("\(p2p.totalUnread)")
                }
            } else {
                Image(systemName: "icloud.and.arrow.down")
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var p2p: P2PEngine
    @Environment(\.openWindow) var openWindow

    var body: some View {
        ForEach(p2p.contacts, id: \.self) { key in
            Text("\(p2p.isOnline(key) ? "🟢" : "⚪️") \(p2p.name(for: key))")
        }
        if p2p.contacts.isEmpty {
            Text("Aucun contact")
        }
        Divider()
        Button("Ouvrir CrocShare") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Ouvrir le dossier CrocShare") {
            try? FileManager.default.createDirectory(at: store.mirrorRootURL,
                                                     withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.mirrorRootURL)
        }
        Divider()
        Button("Rechercher les mises à jour…") { UpdateManager.shared.checkForUpdates() }
        Button("Quitter") { NSApp.terminate(nil) }
    }
}

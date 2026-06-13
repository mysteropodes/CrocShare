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
                    store.crocPath = CrocService.findCroc()
                    if store.config.hostRelay ?? false {
                        RelayServer.shared.start()
                    }
                    engine.start()
                    if store.config.experimentalP2P ?? false {
                        p2p.enable(displayName: store.config.myName)
                    }
                }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            // L'icône affiche le nombre de messages non lus.
            if store.totalUnread > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "icloud.and.arrow.down.fill")
                    Text("\(store.totalUnread)")
                }
            } else {
                Image(systemName: "icloud.and.arrow.down")
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) var openWindow

    var body: some View {
        ForEach(store.contacts) { contact in
            let waiting = store.downloads.filter {
                $0.contactID == contact.id && ($0.status == .waiting || $0.status == .transferring)
            }.count
            Text("\(store.isOnline(contact) ? "🟢" : "⚪️") \(contact.name)"
                 + (waiting > 0 ? " — \(waiting) en attente" : ""))
        }
        if store.contacts.isEmpty {
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

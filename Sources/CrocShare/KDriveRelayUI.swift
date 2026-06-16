import SwiftUI

/// Section Réglages → « Relai kDrive ». Tout est facultatif : tant que
/// `enabled = false`, le module ne tourne pas et n'envoie aucune requête.
/// Le PAT vit dans le Trousseau (jamais sérialisé dans config.json).
struct KDriveRelaySettingsSection: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var p2p: P2PEngine
    @State private var pat: String = KDriveTokenStore.load() ?? ""
    @State private var pingResult: PingResult = .idle
    @State private var showHelp = false

    enum PingResult: Equatable {
        case idle, pinging, ok, fail(String)
    }

    private var cfg: KDriveRelayConfig {
        store.config.kdriveRelay ?? KDriveRelayConfig()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Relai asynchrone (kDrive)").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cfg.enabled },
                    set: { newValue in
                        var c = cfg; c.enabled = newValue
                        store.config.kdriveRelay = c
                        Task { await KDriveRelay.shared.updateEnabled(newValue) }
                    }
                )).toggleStyle(.switch).labelsHidden()
            }
            Text("Quand un contact est hors ligne, les messages sont stockés chiffrés sur un dossier kDrive puis livrés et supprimés à sa reconnexion. Optionnel.")
                .font(.caption).foregroundStyle(.secondary)

            if cfg.enabled {
                LabeledContent("Drive ID") {
                    TextField("ex. 123456", text: Binding(
                        get: { cfg.driveID },
                        set: { var c = cfg; c.driveID = $0.trimmingCharacters(in: .whitespaces); store.config.kdriveRelay = c }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LabeledContent("Dossier ID (racine du relai)") {
                    TextField("ex. 789012", text: Binding(
                        get: { cfg.folderID },
                        set: { var c = cfg; c.folderID = $0.trimmingCharacters(in: .whitespaces); store.config.kdriveRelay = c }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LabeledContent("Personal Access Token") {
                    HStack {
                        SecureField("collé depuis manager.infomaniak.com", text: $pat)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                        Button("Enregistrer") {
                            if pat.isEmpty { KDriveTokenStore.clear() }
                            else { KDriveTokenStore.save(pat) }
                            pingResult = .idle
                        }
                        if KDriveTokenStore.load() != nil {
                            Button("Effacer") { KDriveTokenStore.clear(); pat = ""; pingResult = .idle }
                                .foregroundStyle(Theme.danger)
                        }
                    }
                }
                LabeledContent("Poll (secondes)") {
                    Stepper(value: Binding(
                        get: { cfg.pollSeconds },
                        set: { var c = cfg; c.pollSeconds = max(15, $0); store.config.kdriveRelay = c }
                    ), in: 15...600, step: 15) {
                        Text("\(cfg.pollSeconds) s")
                    }.frame(width: 160)
                }
                LabeledContent("Purge auto (jours)") {
                    Stepper(value: Binding(
                        get: { cfg.maxAgeSeconds / 86400 },
                        set: { var c = cfg; c.maxAgeSeconds = max(1, $0) * 86400; store.config.kdriveRelay = c }
                    ), in: 1...30) {
                        Text("\(cfg.maxAgeSeconds / 86400) j")
                    }.frame(width: 160)
                }

                HStack(spacing: 10) {
                    Button("Tester la connexion") {
                        Task { await testConnection() }
                    }
                    switch pingResult {
                    case .idle: EmptyView()
                    case .pinging: ProgressView().controlSize(.small)
                    case .ok:
                        Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    case .fail(let m):
                        Label(m, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                            .lineLimit(2).frame(maxWidth: 320, alignment: .leading)
                    }
                    Spacer()
                    Button("Aide…") { showHelp = true }.font(.caption)
                }
            }
        }
        .sheet(isPresented: $showHelp) { KDriveRelayHelpSheet() }
    }

    private func testConnection() async {
        pingResult = .pinging
        do {
            try await KDriveRelay.shared.testConnection()
            await MainActor.run { pingResult = .ok }
        } catch {
            await MainActor.run { pingResult = .fail(error.localizedDescription) }
        }
    }
}

private struct KDriveRelayHelpSheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configurer le relai kDrive").font(.title3.bold())
            Group {
                Text("1.  Va sur manager.infomaniak.com → ton profil → menu de gauche → **Tokens API**.")
                Text("    ⚠️ PAS « Application API » (c'est pour les flux OAuth complets — pas utile ici).")
                    .foregroundStyle(.secondary)
                Text("2.  Clique « Créer un token » et coche ces scopes :")
                Text("       • drive:file:read   (lister + télécharger)")
                    .font(.system(.callout, design: .monospaced))
                Text("       • drive:file:write  (uploader + supprimer)")
                    .font(.system(.callout, design: .monospaced))
                Text("    Si l'UI ne montre que `drive`, c'est le scope parent — il suffit.")
                    .foregroundStyle(.secondary)
                Text("3.  Note l'ID de ton Drive : il apparaît dans l'URL kdrive.infomaniak.com/app/drive/<ID>/.")
                Text("4.  Dans le Drive, crée à la racine un dossier `crocshare-relay` (ou autre nom).")
                Text("5.  Ouvre ce dossier dans le navigateur, son ID est dans l'URL .../files/<ID>.")
                Text("6.  Colle ces trois valeurs ci-contre, clique Enregistrer puis Tester.")
            }.font(.callout)
            Divider()
            Text("Sécurité : le PAT vit dans ton Trousseau macOS, jamais dans config.json. Les messages déposés sur kDrive sont chiffrés AES-GCM avec la clé déjà négociée à l'appairage P2P : le serveur ne voit qu'un blob opaque.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 540)
    }
}

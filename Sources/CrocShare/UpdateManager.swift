import Foundation
import AppKit
import Sparkle

// MARK: - UpdateManager
// Même modèle que RecentDrop : singleton qui encapsule Sparkle
// (SPUStandardUpdaterController).
// - Vérification automatique au lancement (intervalle dans Info.plist)
// - Vérification manuelle depuis le menu de la barre de menus
// - Signature EdDSA validée par Sparkle ; l'app est remplacée et relancée
//   automatiquement, avec la notification de mise à jour de Sparkle.

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private var controller: SPUStandardUpdaterController?

    func start() {
        // Sparkle exige un vrai bundle .app (inopérant via `swift run`).
        guard Bundle.main.bundleIdentifier != nil, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Check manuel (« Rechercher les mises à jour… » du menu).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

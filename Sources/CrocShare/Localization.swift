import SwiftUI
import Foundation
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Localization runtime override.
//
// macOS choisit normalement la langue via les préférences système. On l'autorise
// à être surchargée par l'utilisateur via AppleLanguages dans UserDefaults
// (effectif au prochain démarrage).
//
// Utilisation : `Text(LocalizationManager.string("settings.title"))` ou
// `Text(L10n.settingsTitle)` plus haut niveau.
// ─────────────────────────────────────────────────────────────────────────────

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case fr = "fr"
    case en = "en"

    var id: String { rawValue }
    var displayKey: String {
        switch self {
        case .system: return "settings.language_system"
        case .fr:     return "settings.language_french"
        case .en:     return "settings.language_english"
        }
    }
}

enum LocalizationManager {
    private static let languageDefaultsKey = "AppleLanguages"
    private static let appOverrideKey = "CrocShareLanguageOverride"

    /// Préférence stockée par l'utilisateur (vide = pas de surcharge).
    static var preferred: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: appOverrideKey) ?? ""
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appOverrideKey)
            applyToBundleAndDefaults(newValue)
        }
    }

    /// Effectif au prochain lancement : pose AppleLanguages selon override.
    /// Pour un changement immédiat, voir SwiftUI \.locale env (limité).
    static func applyToBundleAndDefaults(_ lang: AppLanguage) {
        switch lang {
        case .system:
            UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
        case .fr, .en:
            UserDefaults.standard.set([lang.rawValue], forKey: languageDefaultsKey)
        }
    }

    /// Lecture d'une chaîne localisée selon la préférence courante.
    /// Si on veut une trad live sans relance, on contourne le NSLocalizedString
    /// standard en chargeant directement le bundle .lproj choisi.
    static func string(_ key: String, comment: String = "") -> String {
        if let bundle = currentBundle() {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return NSLocalizedString(key, comment: comment)
    }

    private static func currentBundle() -> Bundle? {
        let lang = preferred
        switch lang {
        case .system:
            return Bundle.module
        case .fr, .en:
            guard let path = Bundle.module.path(forResource: lang.rawValue, ofType: "lproj"),
                  let b = Bundle(path: path) else {
                return Bundle.module
            }
            return b
        }
    }

    /// Locale courante (pour les composants SwiftUI qui acceptent \.locale).
    static var currentLocale: Locale {
        switch preferred {
        case .system: return .current
        case .fr:     return Locale(identifier: "fr")
        case .en:     return Locale(identifier: "en")
        }
    }

    /// Relance l'app pour appliquer la nouvelle langue (NSWorkspace.openApplication
    /// puis NSApp.terminate). Le path du bundle courant est utilisé.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [bundleURL.path]
        do {
            try task.run()
            // Petit délai pour laisser le launch se faire avant kill.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
                // Fallback : si terminate est bloqué (sandbox, etc.) on force.
                exit(0)
            }
        } catch {
            NSApp.terminate(nil)
        }
    }
}

/// Sucre syntaxique : `L10n("settings.title")` ou via dynamic member dans une
/// future itération. Pour l'instant on garde simple.
func L10n(_ key: String) -> String {
    LocalizationManager.string(key)
}

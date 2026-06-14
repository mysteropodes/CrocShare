import SwiftUI
import AppKit

// Système de design (tokens) — charte « minimalisme fonctionnel », clair/sombre.
// Couleurs sémantiques dynamiques (s'adaptent au thème système), espacements,
// rayons et typographie cohérents dans toute l'app.

extension NSColor {
    /// Couleur dynamique clair/sombre.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Theme {
    // Couleur d'accent (bleu roi), légèrement plus claire en sombre.
    static let accent = Color(NSColor.dynamic(light: NSColor(hex: 0x2563EB), dark: NSColor(hex: 0x3B82F6)))

    // Fonds
    static let bgApp = Color(NSColor.dynamic(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x1B1B1D)))
    static let surface = Color(NSColor.dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x252528)))
    static let surfaceAlt = Color(NSColor.dynamic(light: NSColor(hex: 0xF0F0F2), dark: NSColor(hex: 0x2C2C30)))
    static let hover = Color(NSColor.dynamic(light: NSColor(hex: 0xF3F4F6), dark: NSColor(hex: 0x303035)))
    static var selected: Color { accent.opacity(0.14) }

    // Texte
    static let textPrimary = Color(NSColor.dynamic(light: NSColor(hex: 0x1F2024), dark: NSColor(hex: 0xF2F2F4)))
    static let textSecondary = Color(NSColor.dynamic(light: NSColor(hex: 0x6B6B70), dark: NSColor(hex: 0x9A9AA0)))
    static let separator = Color(NSColor.dynamic(light: NSColor(hex: 0xE6E6EA), dark: NSColor(hex: 0x37373C)))

    // États
    static let danger = Color(NSColor(hex: 0xDC2626))
    static let success = Color(NSColor(hex: 0x059669))
    static let online = Color(NSColor(hex: 0x22C55E))
    static let away = Color(NSColor(hex: 0xF59E0B))

    // Espacements (échelle 4 / 8)
    enum Space { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }
    // Rayons
    enum Radius { static let sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16 }

    // Typographie
    static var h1: Font { .system(size: 24, weight: .semibold) }
    static var h2: Font { .system(size: 18, weight: .semibold) }
    static var body: Font { .system(size: 14) }
    static var small: Font { .system(size: 12, weight: .medium) }
    static var tiny: Font { .system(size: 11, weight: .medium) }
}

// Carte de surface réutilisable (fond + rayon + ombre douce).
struct Card: ViewModifier {
    var radius: CGFloat = Theme.Radius.md
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        )
    }
}
extension View { func card(radius: CGFloat = Theme.Radius.md) -> some View { modifier(Card(radius: radius)) } }

/// Pastille de présence (en ligne / absent / hors ligne).
struct PresenceDot: View {
    let online: Bool
    var size: CGFloat = 10
    var body: some View {
        Circle()
            .fill(online ? Theme.online : Color.gray.opacity(0.55))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
    }
}

/// Zone de dépôt de fichier (drag & drop) avec retour visuel actif :
/// bordure accent + fond teinté + « Déposez pour envoyer ».
import UniformTypeIdentifiers

struct FileDropZone: ViewModifier {
    @EnvironmentObject var p2p: P2PEngine
    let scope: String
    let label: String
    let onAttach: (P2PEngine.P2PAttachment) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.accent.opacity(0.07))
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                        Label(label, systemImage: "arrow.down.doc.fill")
                            .font(Theme.h2).foregroundStyle(Theme.accent)
                    }
                    .padding(8).allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.isFileURL else { return }
                        Task { @MainActor in
                            if let att = p2p.importChatFile(url, scope: scope) { onAttach(att) }
                        }
                    }
                }
                return true
            }
    }
}

extension View {
    func fileDropZone(scope: String, label: String = "Déposez pour envoyer",
                      onAttach: @escaping (P2PEngine.P2PAttachment) -> Void) -> some View {
        modifier(FileDropZone(scope: scope, label: label, onAttach: onAttach))
    }
}

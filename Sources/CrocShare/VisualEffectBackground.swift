import SwiftUI
import AppKit

/// Fond translucide style macOS (NSVisualEffectView). Utilisé sur la sidebar
/// pour le rendu vibrancy façon Finder/Mail. Avec `.behindWindow`, nécessite
/// que la fenêtre soit non-opaque — c'est ce que fait `WindowConfigurator`.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Rend la NSWindow hôte non-opaque (background clear) afin que les
/// `VisualEffectBackground` en mode `.behindWindow` puissent réellement laisser
/// transparaître ce qui est derrière (bureau, autres fenêtres). À placer en
/// `.background()` du root SwiftUI une fois suffit.
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void = { win in
        win.isOpaque = false
        win.backgroundColor = .clear
        // Conserver une ombre native, des coins arrondis, etc.
        win.hasShadow = true
    }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let win = v.window { configure(win) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let win = nsView.window { configure(win) }
    }
}

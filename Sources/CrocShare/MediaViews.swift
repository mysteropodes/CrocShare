import SwiftUI
import AVKit
import WebKit
import RiveRuntime
import PDFKit

/// GIF animé. Le wrapper NSImageView ne propage pas son intrinsicSize à
/// SwiftUI quand on l'utilise seul ; on implémente `sizeThatFits` pour que
/// SwiftUI choisisse une taille qui rentre dans le maxWidth/maxHeight du
/// parent tout en préservant l'aspect ratio natif du GIF.
struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.canDrawSubviewsIntoLayer = true
        v.image = NSImage(contentsOf: url)
        // Ne pas hugger : on veut bien remplir l'espace que SwiftUI donne.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil {
            nsView.image = NSImage(contentsOf: url)
            nsView.animates = true
        }
    }

    /// Taille proposée à SwiftUI : on encadre le GIF dans la proposition du
    /// parent tout en respectant son aspect ratio (intrinsicSize de l'image).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        let intrinsic = nsView.image?.size ?? CGSize(width: 320, height: 180)
        guard intrinsic.width > 0, intrinsic.height > 0 else { return intrinsic }
        let ratio = intrinsic.width / intrinsic.height
        let w = proposal.width ?? intrinsic.width
        let h = proposal.height ?? intrinsic.height
        // Fit-inside : essaye d'occuper l'espace proposé sans dépasser l'aspect.
        let byWidth = CGSize(width: w, height: w / ratio)
        let byHeight = CGSize(width: h * ratio, height: h)
        return byWidth.height <= h ? byWidth : byHeight
    }
}

/// Preview universel basé sur l'extension : image, vidéo, Rive, PDF, texte, ou
/// vignette fallback. À utiliser quand on a un fichier local prêt à afficher.
struct RichFilePreview: View {
    let url: URL
    var maxHeight: CGFloat = 260
    var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        Group {
            switch ext {
            case "gif":
                AnimatedGIFView(url: url).frame(maxHeight: maxHeight)
            case "png","jpg","jpeg","heic","webp","tiff", "bmp":
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: maxHeight)
                } else {
                    fallback
                }
            case "mp4","mov","m4v","mkv":
                VideoBubble(url: url).frame(maxHeight: maxHeight)
            case "riv":
                RiveBubble(url: url, fixedSize: false).frame(maxHeight: maxHeight)
            case "pdf":
                PDFPreview(url: url).frame(maxHeight: maxHeight)
            case "txt","md","markdown","json","csv","log","rtf","xml","yaml","yml","swift","js","ts","py","sh","html","css":
                TextPreview(url: url).frame(maxHeight: maxHeight)
            default:
                fallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12))
            Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.secondary)
        }
        .frame(height: maxHeight)
    }
}

/// Viewer PDF inline (PDFKit). Affiche la première page.
struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = true
        v.displayMode = .singlePage
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document == nil { nsView.document = PDFDocument(url: url) }
    }
}

/// Viewer texte simple, monospace pour code, tronqué aux N premiers Ko pour ne
/// pas faire ramer l'UI sur des fichiers énormes.
struct TextPreview: View {
    let url: URL
    @State private var content: String = ""
    @State private var truncated = false
    private let maxBytes = 64 * 1024

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.gray.opacity(0.08))
        .overlay(alignment: .bottom) {
            if truncated {
                Text("Aperçu tronqué (\(maxBytes / 1024) Ko)").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(6)
            }
        }
        .task(id: url) { await load() }
    }

    private var monospaced: Bool {
        ["json","csv","log","md","markdown","xml","yaml","yml","swift","js","ts","py","sh","html","css"]
            .contains(url.pathExtension.lowercased())
    }

    private func load() async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        await MainActor.run {
            truncated = size > maxBytes
            content = String(data: data.prefix(maxBytes), encoding: .utf8) ?? "[binaire]"
        }
    }
}

/// Lecteur vidéo dans une bulle, basé sur AVPlayerView (AppKit).
/// Le VideoPlayer de SwiftUI (_AVKit_SwiftUI) plante à l'initialisation de ses
/// métadonnées dans les apps construites hors Xcode — crash confirmé au rapport.
/// La taille est délibérément flexible : le conteneur parent applique la
/// frame souhaitée (chat : maxWidth 360 + aspectRatio ; lightbox : plein écran).
struct VideoBubble: View {
    let url: URL

    var body: some View {
        PlayerContainer(url: url)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct PlayerContainer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// Animation Rive (.riv) jouée directement dans la bulle (runtime officiel).
/// `fixedSize` = true → taille bulle compacte (chat). false → s'étire au
/// conteneur parent (lightbox/panel droit).
struct RiveBubble: View {
    let url: URL
    var fixedSize: Bool = true
    @State private var viewModel: RiveViewModel?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let viewModel {
                viewModel.view()
            } else if failed {
                Label("Animation illisible", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .modifier(RiveSizeModifier(fixedSize: fixedSize))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            guard viewModel == nil, !failed else { return }
            do {
                let data = try Data(contentsOf: url)
                let file = try RiveFile(byteArray: [UInt8](data), loadCdn: true)
                viewModel = RiveViewModel(RiveModel(riveFile: file))
            } catch {
                failed = true
            }
        }
        .onDisappear { viewModel = nil }
    }
}

private struct RiveSizeModifier: ViewModifier {
    let fixedSize: Bool
    func body(content: Content) -> some View {
        if fixedSize {
            content.frame(width: 300, height: 220)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Prévisualisation interactive d'un lien de partage rive.app, embarquée en WKWebView.
struct RiveLinkPreview: View {
    let url: URL

    var body: some View {
        WebContainer(url: url)
            .frame(width: 340, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square.fill")
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Ouvrir dans le navigateur")
            }
    }

    /// Premier lien rive.app trouvé dans un texte (pour la préview).
    static func riveLink(in text: String) -> URL? {
        guard text.contains("rive.app"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, url.host?.contains("rive.app") == true {
                return url
            }
        }
        return nil
    }
}

private struct WebContainer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

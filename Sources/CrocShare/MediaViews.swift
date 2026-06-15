import SwiftUI
import AVKit
import WebKit
import RiveRuntime
import PDFKit

/// Vue NSImageView wrappée pour lire les GIF animés (SwiftUI Image les fige).
struct AnimatedGIFView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.canDrawSubviewsIntoLayer = true
        return v
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil {
            nsView.image = NSImage(contentsOf: url)
            nsView.animates = true
        }
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
                RiveBubble(url: url).frame(maxHeight: maxHeight)
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
struct VideoBubble: View {
    let url: URL

    var body: some View {
        PlayerContainer(url: url)
            .frame(width: 300, height: 180)
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
struct RiveBubble: View {
    let url: URL
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
        .frame(width: 300, height: 220)
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

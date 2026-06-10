import SwiftUI
import AVKit
import WebKit
import RiveRuntime

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

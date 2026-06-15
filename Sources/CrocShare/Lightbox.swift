import SwiftUI
import AppKit

/// Wrapper Identifiable pour pouvoir piloter un sheet avec un `URL?`.
struct IdentifiedURL: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Lightbox plein écran (sheet) pour agrandir un fichier image/PDF/texte/Rive.
/// Pour les vidéos, on préfère `VideoReviewSheet` (commentaires timeline).
struct FileLightbox: View {
    let url: URL
    var onClose: () -> Void

    private var ext: String { url.pathExtension.lowercased() }
    private var isVideo: Bool { ["mp4","mov","m4v","mkv"].contains(ext) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                if isVideo {
                    VideoBubble(url: url)
                        .frame(width: geo.size.width * 0.86, height: geo.size.height * 0.78)
                } else {
                    RichFilePreview(url: url, maxHeight: geo.size.height * 0.86)
                        .padding(24)
                }
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Ouvrir", systemImage: "arrow.up.right.square")
                            }
                            Button { revealInFinder() } label: {
                                Image(systemName: "folder")
                            }
                            .help("Afficher dans le Finder")
                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill").font(.title2)
                            }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .help("Fermer")
                        }
                        .padding(10)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(.trailing, 24).padding(.top, 24)
                    }
                    Spacer()
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onExitCommand(perform: onClose)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

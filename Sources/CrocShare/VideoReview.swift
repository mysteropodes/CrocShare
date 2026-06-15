import SwiftUI
import AppKit
import AVFoundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// Vidéo : lecteur grand format avec panneau de commentaires timestampés
// façon Frame.io. Persistance locale (UserDefaults) par identifiant de message,
// indépendant du chemin du fichier.
// ─────────────────────────────────────────────────────────────────────────────

/// Trait à main levée : couleur, épaisseur, points en coordonnées normalisées
/// (0…1 du conteneur) pour rester correct quel que soit le zoom du lecteur.
struct AnnotationStroke: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var color: String              // hex (#RRGGBB)
    var width: Double
    var points: [CGPointCodable]
}

struct CGPointCodable: Codable, Hashable {
    var x: Double, y: Double
    init(_ p: CGPoint) { x = p.x; y = p.y }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

struct VideoComment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestamp: Double          // secondes
    var author: String
    var date: Date
    var text: String
    /// Réponse à un commentaire racine ; nil = racine.
    var parentId: UUID? = nil
    /// Annotations dessin associées (affichées à `timestamp` sur la vidéo).
    var strokes: [AnnotationStroke] = []
    /// Marqué « traité / OK » par n'importe quel relecteur.
    var isValidated: Bool = false
    /// Identifiant du message P2P parent (pour synchro multi-pair).
    var messageRef: UUID? = nil
}

/// Notification émise quand un commentaire vidéo/image arrive via P2P.
extension Notification.Name {
    static let crocShareVideoCommentArrived = Notification.Name("crocshare.video-comment-arrived")
}

/// Opération sur un commentaire (transmise en P2P).
struct VideoCommentOp: Codable {
    enum Action: String, Codable { case upsert, delete }
    var action: Action
    var messageID: UUID         // identifiant du message porteur de l'attachment
    var comment: VideoComment?  // requis pour `upsert`
    var commentID: UUID?        // requis pour `delete`
}

/// Helpers de comptage sans instancier les stores (pour les pastilles de chat).
enum CommentCountHelper {
    static func videoCount(messageID: UUID) -> (total: Int, validated: Int) {
        load(key: "crocshare.video-comments.\(messageID.uuidString)")
    }
    static func imageCount(messageID: UUID) -> (total: Int, validated: Int) {
        load(key: "crocshare.image-comments.\(messageID.uuidString)")
    }
    private static func load(key: String) -> (Int, Int) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([VideoComment].self, from: data) else { return (0, 0) }
        let roots = arr.filter { $0.parentId == nil }
        return (arr.count, roots.filter(\.isValidated).count)
    }
}

/// Pastille N commentaires + validés sur les attachments du chat.
struct CommentCountBadge: View {
    let messageID: UUID
    let isImage: Bool
    @State private var total: Int = 0
    @State private var validated: Int = 0
    @State private var observer: NSObjectProtocol?

    var body: some View {
        Group {
            if total > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 9))
                    Text("\(total)").font(.caption2.monospacedDigit().bold())
                    if validated > 0 && validated == rootCount {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9)).foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                .foregroundStyle(.white)
            }
        }
        .onAppear {
            refresh()
            observer = NotificationCenter.default.addObserver(
                forName: .crocShareVideoCommentArrived, object: nil, queue: .main
            ) { _ in refresh() }
        }
        .onDisappear {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private var rootCount: Int { total }   // approximation : on n'a pas la séparation racines/réponses ici

    private func refresh() {
        let r = isImage
            ? CommentCountHelper.imageCount(messageID: messageID)
            : CommentCountHelper.videoCount(messageID: messageID)
        total = r.total
        validated = r.validated
    }
}

/// Stockage simple par messageID dans UserDefaults. Suffisant pour du local ;
/// si on veut diffuser les commentaires aux pairs, brancher sur P2PEngine.
@MainActor
final class VideoCommentsStore: ObservableObject {
    @Published private(set) var comments: [VideoComment] = []
    let messageID: UUID
    private let key: String
    private var notifObserver: NSObjectProtocol?
    /// Pairs avec qui synchroniser : injecté à l'ouverture du sheet.
    var syncTargets: [String] = []
    /// Callback de broadcast (signature : opData → pairs). Injecté par la sheet.
    var onBroadcast: ((Data, [String]) -> Void)?

    init(messageID: UUID) {
        self.messageID = messageID
        self.key = "crocshare.video-comments.\(messageID.uuidString)"
        load()
        // Réception des commentaires venant des pairs.
        notifObserver = NotificationCenter.default.addObserver(
            forName: .crocShareVideoCommentArrived, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let op = note.userInfo?["op"] as? VideoCommentOp,
                  op.messageID == self.messageID
            else { return }
            Task { @MainActor in self.applyRemote(op) }
        }
    }

    deinit {
        if let notifObserver { NotificationCenter.default.removeObserver(notifObserver) }
    }

    private func applyRemote(_ op: VideoCommentOp) {
        switch op.action {
        case .upsert:
            guard let c = op.comment else { return }
            if let idx = comments.firstIndex(where: { $0.id == c.id }) {
                comments[idx] = c
            } else {
                comments.append(c)
            }
            sortComments(); save()
        case .delete:
            guard let id = op.commentID else { return }
            comments.removeAll { $0.id == id || $0.parentId == id }
            save()
        }
    }

    func setValidated(_ id: UUID, _ value: Bool) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].isValidated = value
        save()
        broadcastUpsert(comments[i])
    }

    func updateText(_ id: UUID, _ text: String) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].text = text
        save()
        broadcastUpsert(comments[i])
    }

    func get(_ id: UUID) -> VideoComment? { comments.first { $0.id == id } }

    private func sortComments() {
        comments.sort { ($0.parentId == nil ? 0 : 1, $0.timestamp, $0.date) < ($1.parentId == nil ? 0 : 1, $1.timestamp, $1.date) }
    }

    func add(timestamp: Double, author: String, text: String,
             parentId: UUID? = nil, strokes: [AnnotationStroke] = []) -> VideoComment {
        let c = VideoComment(timestamp: timestamp, author: author, date: Date(),
                             text: text, parentId: parentId, strokes: strokes,
                             messageRef: messageID)
        comments.append(c)
        sortComments()
        save()
        broadcastUpsert(c)
        return c
    }

    func remove(_ id: UUID) {
        // Supprimer aussi les réponses orphelines.
        comments.removeAll { $0.id == id || $0.parentId == id }
        save()
        broadcastDelete(id)
    }

    private func broadcastUpsert(_ c: VideoComment) {
        guard let onBroadcast, !syncTargets.isEmpty else { return }
        let op = VideoCommentOp(action: .upsert, messageID: messageID, comment: c, commentID: nil)
        if let data = try? JSONEncoder().encode(op) { onBroadcast(data, syncTargets) }
    }
    private func broadcastDelete(_ id: UUID) {
        guard let onBroadcast, !syncTargets.isEmpty else { return }
        let op = VideoCommentOp(action: .delete, messageID: messageID, comment: nil, commentID: id)
        if let data = try? JSONEncoder().encode(op) { onBroadcast(data, syncTargets) }
    }

    /// Commentaires racines, triés par timestamp.
    var roots: [VideoComment] {
        comments.filter { $0.parentId == nil }.sorted { $0.timestamp < $1.timestamp }
    }
    func replies(of id: UUID) -> [VideoComment] {
        comments.filter { $0.parentId == id }.sorted { $0.date < $1.date }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        comments = (try? JSONDecoder().decode([VideoComment].self, from: data)) ?? []
    }
    private func save() {
        if let data = try? JSONEncoder().encode(comments) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Player partagé : expose `currentTime`, `duration`, et les commandes
/// play/pause/seek. Utilisé conjointement par la vue lecteur et le panneau
/// commentaires (pour seek au clic + scrubber synchronisé).
@MainActor
final class VideoPlayerEngine: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    private var timeObserver: Any?

    init(url: URL) {
        self.player = AVPlayer(url: url)
        let item = player.currentItem
        // Observation du temps courant (4×/s).
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds
        }
        // Récup de la durée (asynchrone).
        Task {
            if let dur = try? await item?.asset.load(.duration), dur.isValid, !CMTIME_IS_INDEFINITE(dur) {
                await MainActor.run { self.duration = dur.seconds }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct VideoReviewSheet: View {
    let url: URL
    let messageID: UUID
    var syncTargets: [String] = []
    var onClose: () -> Void

    @EnvironmentObject var p2p: P2PEngine
    @StateObject private var engine: VideoPlayerEngine
    @StateObject private var commentsStore: VideoCommentsStore
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool

    // Annotation dessin.
    @State private var drawingMode = false
    @State private var drawingStrokes: [AnnotationStroke] = []
    @State private var currentColor: Color = .red
    @State private var currentWidth: Double = 3

    // Réponse à un commentaire racine (nil = nouveau commentaire racine).
    @State private var replyingTo: VideoComment? = nil

    init(url: URL, messageID: UUID, syncTargets: [String] = [], onClose: @escaping () -> Void) {
        self.url = url
        self.messageID = messageID
        self.syncTargets = syncTargets
        self.onClose = onClose
        _engine = StateObject(wrappedValue: VideoPlayerEngine(url: url))
        _commentsStore = StateObject(wrappedValue: VideoCommentsStore(messageID: messageID))
    }

    /// Strokes à afficher à `t` ± 1 s (commentaire actif).
    private var strokesToShow: [AnnotationStroke] {
        let visible = commentsStore.comments
            .filter { abs($0.timestamp - engine.currentTime) < 1.0 && !$0.strokes.isEmpty }
            .flatMap { $0.strokes }
        return drawingMode ? drawingStrokes : (drawingStrokes + visible)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Lecteur avec overlay dessin.
                ZStack {
                    Color.black
                    AVPlayerNSView(player: engine.player)
                    DrawingCanvas(strokes: drawingMode ? $drawingStrokes : .constant(strokesToShow),
                                  enabled: drawingMode,
                                  color: $currentColor,
                                  width: $currentWidth)
                        .allowsHitTesting(drawingMode)
                    if drawingMode {
                        VStack { Spacer()
                            DrawingToolbar(color: $currentColor, width: $currentWidth,
                                           hasStrokes: !drawingStrokes.isEmpty,
                                           onUndo: { if !drawingStrokes.isEmpty { drawingStrokes.removeLast() } },
                                           onClear: { drawingStrokes.removeAll() })
                                .padding(.bottom, 20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Barre transport + scrubber avec markers.
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Button { engine.togglePlay(); if engine.isPlaying { drawingMode = false } } label: {
                            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }.buttonStyle(.plain)
                        Text(timeString(engine.currentTime)).monospacedDigit().font(.caption)
                        TimelineScrubber(
                            currentTime: engine.currentTime,
                            duration: max(engine.duration, 0.01),
                            markers: commentsStore.roots.map(\.timestamp),
                            onSeek: { engine.seek(to: $0) }
                        )
                        Text(timeString(engine.duration)).monospacedDigit().font(.caption)
                            .foregroundStyle(.secondary)
                        // Toggle dessin (auto-pause).
                        Button {
                            if !drawingMode { engine.pause() }
                            drawingMode.toggle()
                        } label: {
                            Image(systemName: drawingMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .font(.title3)
                                .foregroundStyle(drawingMode ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain)
                        .help(drawingMode ? "Désactiver l'annotation" : "Annoter (pause auto)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .background(.thinMaterial)
            }
            Divider()
            // Panneau commentaires.
            VStack(spacing: 0) {
                HStack {
                    Text("Commentaires").font(.headline)
                    Spacer()
                    Text("\(commentsStore.comments.count)").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceAlt))
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if commentsStore.roots.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                    .font(.title2).foregroundStyle(.tertiary)
                                Text("Aucun commentaire").font(.callout).foregroundStyle(.secondary)
                                Text("Mets pause, dessine si tu veux, puis tape un commentaire.")
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            ForEach(commentsStore.roots) { c in
                                VideoCommentThread(c: c,
                                                   replies: commentsStore.replies(of: c.id),
                                                   onSeek: { engine.seek(to: c.timestamp) },
                                                   onReply: { replyingTo = c; draftFocused = true },
                                                   onDelete: { commentsStore.remove(c.id) },
                                                   onSaveEdit: { commentsStore.updateText($0, $1) },
                                                   onToggleValidated: { id in
                                                       let cur = commentsStore.get(id)?.isValidated ?? false
                                                       commentsStore.setValidated(id, !cur)
                                                   })
                            }
                        }
                    }
                    .padding(10)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let parent = replyingTo {
                            Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Color.accentColor)
                            Text("Réponse à \(parent.author)").font(.caption)
                            Spacer()
                            Button { replyingTo = nil } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            Text("À \(timeString(engine.currentTime))").font(.caption.monospacedDigit())
                            Spacer()
                            if !drawingStrokes.isEmpty {
                                Label("\(drawingStrokes.count) trait\(drawingStrokes.count > 1 ? "s" : "") prêt(s)",
                                      systemImage: "scribble.variable")
                                    .font(.caption2).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        TextField(replyingTo == nil ? "Commenter cet instant…" : "Répondre…",
                                  text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($draftFocused)
                            .lineLimit(1...4)
                            .onSubmit { addComment() }
                        Button { addComment() } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            }
            .frame(width: 320)
            .background(Theme.surface)
        }
        .frame(minWidth: 980, minHeight: 600)
        .onExitCommand(perform: onClose)
        .onAppear {
            commentsStore.syncTargets = syncTargets
            commentsStore.onBroadcast = { data, keys in p2p.broadcastCommentOp(data, to: keys) }
        }
    }

    private func addComment() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let author = p2p.myName.isEmpty ? "Moi" : p2p.myName
        if let parent = replyingTo {
            _ = commentsStore.add(timestamp: parent.timestamp, author: author, text: t,
                                  parentId: parent.id, strokes: [])
            replyingTo = nil
        } else {
            _ = commentsStore.add(timestamp: engine.currentTime, author: author, text: t,
                                  strokes: drawingStrokes)
            drawingStrokes = []
            drawingMode = false
        }
        draft = ""
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Ligne commentaire dans le panneau de droite.
private struct CommentRow: View {
    let c: VideoComment
    var onSeek: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onSeek) {
                    Label(timeString(c.timestamp), systemImage: "play.circle.fill")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain).help("Sauter à ce moment")
                Text(c.author).font(.caption.weight(.semibold))
                Spacer()
                Text(c.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Text(c.text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover.opacity(0.6) : Theme.surfaceAlt))
        .onHover { hovering = $0 }
    }

    private func timeString(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Scrubber custom : Capsule de progression + tick par commentaire.
/// Drag pour seeker.
private struct TimelineScrubber: View {
    let currentTime: Double
    let duration: Double
    let markers: [Double]
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 5)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * CGFloat(currentTime / duration)), height: 5)
                ForEach(markers, id: \.self) { m in
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .position(x: geo.size.width * CGFloat(m / duration), y: -2)
                }
                Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(x: max(6, min(geo.size.width - 6, geo.size.width * CGFloat(currentTime / duration))),
                              y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let pct = max(0, min(1, v.location.x / geo.size.width))
                onSeek(pct * duration)
            })
        }
        .frame(height: 24)
    }
}

/// AVPlayerLayer dans une NSView (plus léger que AVPlayerView et sans contrôles
/// natifs — on dessine les nôtres).
private struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.player = player
        return v
    }
    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.player = player
    }
}

final class PlayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true; layer = playerLayer }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

// MARK: - Threading commentaires

struct VideoCommentThread: View {
    let c: VideoComment
    let replies: [VideoComment]
    var onSeek: () -> Void
    var onReply: () -> Void
    var onDelete: () -> Void
    var onSaveEdit: (UUID, String) -> Void
    var onToggleValidated: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoCommentBubble(c: c, isReply: false,
                               onSeek: onSeek, onReply: onReply, onDelete: onDelete,
                               onSaveEdit: onSaveEdit, onToggleValidated: onToggleValidated)
            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(replies) { r in
                        VideoCommentBubble(c: r, isReply: true,
                                           onSeek: onSeek, onReply: onReply, onDelete: {},
                                           onSaveEdit: onSaveEdit, onToggleValidated: { _ in })
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.separator)
                        .frame(width: 2).padding(.leading, 6)
                }
            }
        }
    }
}

private struct VideoCommentBubble: View {
    let c: VideoComment
    let isReply: Bool
    var onSeek: () -> Void
    var onReply: () -> Void
    var onDelete: () -> Void
    var onSaveEdit: (UUID, String) -> Void
    var onToggleValidated: (UUID) -> Void
    @State private var hovering = false
    @State private var editing = false
    @State private var editDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !isReply {
                    // Pastille validation (cliquable).
                    Button {
                        onToggleValidated(c.id)
                    } label: {
                        Image(systemName: c.isValidated ? "checkmark.seal.fill" : "checkmark.seal")
                            .foregroundStyle(c.isValidated ? .green : .secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(c.isValidated ? "Marqué comme traité" : "Marquer comme traité")
                    // Timestamp cliquable.
                    Button(action: onSeek) {
                        Label(timeString(c.timestamp), systemImage: "play.circle.fill")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }.buttonStyle(.plain).help("Sauter à ce moment")
                }
                Text(c.author).font(.caption.weight(.semibold))
                if !c.strokes.isEmpty {
                    Image(systemName: "scribble.variable").font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .help("\(c.strokes.count) annotation\(c.strokes.count > 1 ? "s" : "")")
                }
                Spacer()
                Text(c.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if hovering && !editing {
                    if !isReply {
                        Button(action: onReply) {
                            Image(systemName: "arrowshape.turn.up.left").font(.caption)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("Répondre")
                    }
                    Button {
                        editDraft = c.text
                        editing = true
                    } label: {
                        Image(systemName: "pencil").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Modifier")
                    if !isReply {
                        Button(action: onDelete) {
                            Image(systemName: "trash").font(.caption)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            // Corps du commentaire : lecture ou édition.
            if editing {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Modifier…", text: $editDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    HStack(spacing: 6) {
                        Button("Annuler") { editing = false }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Enregistrer") {
                            let t = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { onSaveEdit(c.id, t) }
                            editing = false
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(editDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                Text(c.text).font(.callout).textSelection(.enabled)
                    .strikethrough(c.isValidated, color: .secondary)
                    .foregroundStyle(c.isValidated ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover.opacity(0.6) : (isReply ? Theme.surfaceAlt.opacity(0.6) : Theme.surfaceAlt)))
        .onHover { hovering = $0 }
    }

    private func timeString(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Canvas annotation

/// Surface de dessin à main levée. Stocke des `AnnotationStroke` en coordonnées
/// normalisées (0..1) → indépendant du zoom du conteneur.
struct DrawingCanvas: View {
    @Binding var strokes: [AnnotationStroke]
    var enabled: Bool
    @Binding var color: Color
    @Binding var width: Double
    @State private var currentPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for s in strokes {
                    var path = Path()
                    for (i, p) in s.points.enumerated() {
                        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(Color(hex: s.color)),
                               style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round))
                }
                if !currentPoints.isEmpty {
                    var path = Path()
                    for (i, p) in currentPoints.enumerated() {
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled else { return }
                        currentPoints.append(v.location)
                    }
                    .onEnded { _ in
                        guard enabled, !currentPoints.isEmpty else { return }
                        let normalized = currentPoints.map { CGPointCodable(.init(x: $0.x / geo.size.width,
                                                                                 y: $0.y / geo.size.height)) }
                        strokes.append(AnnotationStroke(color: color.hexString,
                                                        width: width, points: normalized))
                        currentPoints = []
                    }
            )
        }
    }
}

struct DrawingToolbar: View {
    @Binding var color: Color
    @Binding var width: Double
    let hasStrokes: Bool
    var onUndo: () -> Void
    var onClear: () -> Void

    private let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
                Button { color = c } label: {
                    Circle().fill(c).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(c.hexString == color.hexString ? Color.white : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                Image(systemName: "scribble").font(.caption)
                Slider(value: $width, in: 1...10).frame(width: 80)
            }
            Divider().frame(height: 18)
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward.circle")
            }.disabled(!hasStrokes)
            Button(action: onClear) {
                Image(systemName: "trash.circle")
            }.disabled(!hasStrokes)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

// MARK: - Sheet review image (commentaires + dessin)

@MainActor
final class ImageCommentsStore: ObservableObject {
    @Published private(set) var comments: [VideoComment] = []
    let messageID: UUID
    private let key: String
    var syncTargets: [String] = []
    var onBroadcast: ((Data, [String]) -> Void)?
    private var notifObserver: NSObjectProtocol?

    init(messageID: UUID) {
        self.messageID = messageID
        self.key = "crocshare.image-comments.\(messageID.uuidString)"
        load()
        notifObserver = NotificationCenter.default.addObserver(
            forName: .crocShareVideoCommentArrived, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let op = note.userInfo?["op"] as? VideoCommentOp,
                  op.messageID == self.messageID else { return }
            Task { @MainActor in self.applyRemote(op) }
        }
    }
    deinit { if let notifObserver { NotificationCenter.default.removeObserver(notifObserver) } }

    private func applyRemote(_ op: VideoCommentOp) {
        switch op.action {
        case .upsert:
            guard let c = op.comment else { return }
            if let i = comments.firstIndex(where: { $0.id == c.id }) { comments[i] = c }
            else { comments.append(c) }
            save()
        case .delete:
            guard let id = op.commentID else { return }
            comments.removeAll { $0.id == id || $0.parentId == id }; save()
        }
    }

    @discardableResult
    func add(author: String, text: String, parentId: UUID? = nil,
             strokes: [AnnotationStroke] = []) -> VideoComment {
        let c = VideoComment(timestamp: 0, author: author, date: Date(),
                             text: text, parentId: parentId, strokes: strokes,
                             messageRef: messageID)
        comments.append(c); save(); broadcastUpsert(c); return c
    }
    func remove(_ id: UUID) {
        comments.removeAll { $0.id == id || $0.parentId == id }; save(); broadcastDelete(id)
    }
    func setValidated(_ id: UUID, _ value: Bool) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].isValidated = value; save(); broadcastUpsert(comments[i])
    }
    func updateText(_ id: UUID, _ text: String) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].text = text; save(); broadcastUpsert(comments[i])
    }
    var roots: [VideoComment] { comments.filter { $0.parentId == nil }.sorted { $0.date < $1.date } }
    func replies(of id: UUID) -> [VideoComment] { comments.filter { $0.parentId == id }.sorted { $0.date < $1.date } }
    func get(_ id: UUID) -> VideoComment? { comments.first { $0.id == id } }

    private func broadcastUpsert(_ c: VideoComment) {
        guard let onBroadcast, !syncTargets.isEmpty else { return }
        let op = VideoCommentOp(action: .upsert, messageID: messageID, comment: c, commentID: nil)
        if let data = try? JSONEncoder().encode(op) { onBroadcast(data, syncTargets) }
    }
    private func broadcastDelete(_ id: UUID) {
        guard let onBroadcast, !syncTargets.isEmpty else { return }
        let op = VideoCommentOp(action: .delete, messageID: messageID, comment: nil, commentID: id)
        if let data = try? JSONEncoder().encode(op) { onBroadcast(data, syncTargets) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        comments = (try? JSONDecoder().decode([VideoComment].self, from: data)) ?? []
    }
    private func save() {
        if let data = try? JSONEncoder().encode(comments) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct ImageReviewSheet: View {
    let url: URL
    let messageID: UUID
    var syncTargets: [String] = []
    var onClose: () -> Void

    @EnvironmentObject var p2p: P2PEngine
    @StateObject private var commentsStore: ImageCommentsStore
    @State private var drawingMode = false
    @State private var draftStrokes: [AnnotationStroke] = []
    @State private var currentColor: Color = .red
    @State private var currentWidth: Double = 3
    @State private var draft = ""
    @State private var replyingTo: VideoComment? = nil
    @FocusState private var draftFocused: Bool

    init(url: URL, messageID: UUID, syncTargets: [String] = [], onClose: @escaping () -> Void) {
        self.url = url
        self.messageID = messageID
        self.syncTargets = syncTargets
        self.onClose = onClose
        _commentsStore = StateObject(wrappedValue: ImageCommentsStore(messageID: messageID))
    }

    private var allStrokes: [AnnotationStroke] {
        let saved = commentsStore.comments.flatMap { $0.strokes }
        return drawingMode ? draftStrokes : (draftStrokes + saved)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("Image illisible").foregroundStyle(.secondary)
                }
                DrawingCanvas(strokes: drawingMode ? $draftStrokes : .constant(allStrokes),
                              enabled: drawingMode,
                              color: $currentColor,
                              width: $currentWidth)
                    .allowsHitTesting(drawingMode)
                VStack {
                    HStack {
                        Spacer()
                        Button { drawingMode.toggle() } label: {
                            Image(systemName: drawingMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .font(.title2)
                                .foregroundStyle(drawingMode ? Color.accentColor : .white)
                                .padding(10).background(Circle().fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                        .help(drawingMode ? "Désactiver l'annotation" : "Annoter")
                    }
                    .padding(12)
                    Spacer()
                    if drawingMode {
                        DrawingToolbar(color: $currentColor, width: $currentWidth,
                                       hasStrokes: !draftStrokes.isEmpty,
                                       onUndo: { if !draftStrokes.isEmpty { draftStrokes.removeLast() } },
                                       onClear: { draftStrokes.removeAll() })
                            .padding(.bottom, 20)
                    }
                }
            }
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Commentaires").font(.headline)
                    Spacer()
                    Text("\(commentsStore.comments.count)").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceAlt))
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if commentsStore.roots.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                    .font(.title2).foregroundStyle(.tertiary)
                                Text("Aucun commentaire").font(.callout).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            ForEach(commentsStore.roots) { c in
                                VideoCommentThread(c: c,
                                                   replies: commentsStore.replies(of: c.id),
                                                   onSeek: {},
                                                   onReply: { replyingTo = c; draftFocused = true },
                                                   onDelete: { commentsStore.remove(c.id) },
                                                   onSaveEdit: { commentsStore.updateText($0, $1) },
                                                   onToggleValidated: { id in
                                                       let cur = commentsStore.get(id)?.isValidated ?? false
                                                       commentsStore.setValidated(id, !cur)
                                                   })
                            }
                        }
                    }.padding(10)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let parent = replyingTo {
                            Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Color.accentColor)
                            Text("Réponse à \(parent.author)").font(.caption)
                            Spacer()
                            Button { replyingTo = nil } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        } else if !draftStrokes.isEmpty {
                            Label("\(draftStrokes.count) trait(s) prêt(s)", systemImage: "scribble.variable")
                                .font(.caption2).foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        TextField(replyingTo == nil ? "Commenter…" : "Répondre…",
                                  text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($draftFocused)
                            .lineLimit(1...4)
                            .onSubmit { addComment() }
                        Button { addComment() } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            }
            .frame(width: 320)
            .background(Theme.surface)
        }
        .frame(minWidth: 980, minHeight: 600)
        .onExitCommand(perform: onClose)
        .onAppear {
            commentsStore.syncTargets = syncTargets
            commentsStore.onBroadcast = { data, keys in p2p.broadcastCommentOp(data, to: keys) }
        }
    }

    private func addComment() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let author = p2p.myName.isEmpty ? "Moi" : p2p.myName
        if let parent = replyingTo {
            commentsStore.add(author: author, text: t, parentId: parent.id, strokes: [])
            replyingTo = nil
        } else {
            commentsStore.add(author: author, text: t, strokes: draftStrokes)
            draftStrokes = []
            drawingMode = false
        }
        draft = ""
    }
}

// MARK: - Helpers couleur hex ↔ Color

extension Color {
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.red
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .red; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

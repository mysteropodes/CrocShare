import SwiftUI
import WebRTC
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

// ─────────────────────────────────────────────────────────────────────────────
// UI placeholder pour les appels. Branchée sur CallEngine.shared.
// L'intégration WebRTC réelle (stasel/WebRTC) arrivera dans une PR dédiée :
// les RTCVideoView/Renderer remplaceront les rectangles de couleur ci-dessous.
// ─────────────────────────────────────────────────────────────────────────────

struct CallButton: View {
    @ObservedObject var engine = CallEngine.shared
    let contactKey: String
    let contactName: String

    var body: some View {
        Menu {
            Button {
                engine.startCall(mode: .audio, with: [contactKey])
            } label: {
                Label(L10n("call.start") + " (audio)", systemImage: "phone")
            }
            Button {
                engine.startCall(mode: .video, with: [contactKey])
            } label: {
                Label(L10n("call.start") + " (vidéo)", systemImage: "video")
            }
        } label: {
            Image(systemName: "phone.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .help(L10n("call.start"))
    }
}

/// Fenêtre/sheet d'appel. À présenter quand `engine.state` n'est pas `.idle`.
struct CallSheet: View {
    @ObservedObject var engine = CallEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            // Grille participants (mosaïque type Zoom). Pour le scaffolding,
            // on dessine des rectangles colorés. À remplacer par RTCMTLVideoView.
            ParticipantGrid(participants: engine.participants)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            CallStatusBar()
                .background(.thinMaterial)

            CallControlBar()
                .background(.thinMaterial)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct ParticipantGrid: View {
    let participants: [CallParticipant]

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int(ceil(Double(participants.count).squareRoot())))
            let rows = max(1, Int(ceil(Double(participants.count) / Double(cols))))
            let w = geo.size.width / CGFloat(cols)
            let h = geo.size.height / CGFloat(rows)
            VStack(spacing: 4) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            if idx < participants.count {
                                ParticipantTile(p: participants[idx])
                                    .frame(width: w - 4, height: h - 4)
                            } else {
                                Color.clear.frame(width: w - 4, height: h - 4)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}

private struct ParticipantTile: View {
    let p: CallParticipant

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [.indigo.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            if p.hasVideo, let track = p.videoTrack {
                RTCVideoTrackView(track: track)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64)).foregroundStyle(.white.opacity(0.85))
            }
            VStack {
                Spacer()
                HStack {
                    Text(p.displayName).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .foregroundStyle(.white)
                    Spacer()
                    if p.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .padding(6).background(Circle().fill(.black.opacity(0.55)))
                            .foregroundStyle(.red)
                    }
                    if p.isScreenSharing {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .padding(6).background(Circle().fill(.black.opacity(0.55)))
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct CallStatusBar: View {
    @ObservedObject var engine = CallEngine.shared
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon).foregroundStyle(statusColor)
            Text(statusText).font(.caption)
            Spacer()
            if !engine.participants.isEmpty {
                let n = engine.participants.count
                Text(String(format: L10n(n > 1 ? "call.participants_many" : "call.participants_one"), n))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var statusIcon: String {
        switch engine.state {
        case .idle, .ended: return "phone.down"
        case .outgoing, .connecting: return "phone.arrow.up.right"
        case .incoming: return "phone.arrow.down.left"
        case .inCall: return "phone.connection"
        }
    }
    private var statusColor: Color {
        switch engine.state {
        case .inCall: return .green
        case .outgoing, .connecting, .incoming: return .orange
        default: return .secondary
        }
    }
    private var statusText: String {
        switch engine.state {
        case .idle: return ""
        case .outgoing: return L10n("call.calling")
        case .incoming(let invite): return String(format: L10n("call.incoming"), invite.fromName)
        case .connecting: return L10n("call.calling")
        case .inCall: return L10n("call.connected")
        case .ended(let r): return r
        }
    }
}

private struct CallControlBar: View {
    @ObservedObject var engine = CallEngine.shared
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            roundButton(systemName: engine.isMicMuted ? "mic.slash.fill" : "mic.fill",
                        tint: engine.isMicMuted ? .red : .white) {
                engine.isMicMuted.toggle()
            }
            roundButton(systemName: engine.isCameraOn ? "video.fill" : "video.slash.fill",
                        tint: engine.isCameraOn ? .white : .red) {
                engine.isCameraOn.toggle()
            }
            roundButton(systemName: "rectangle.on.rectangle.angled",
                        tint: engine.isScreenSharing ? .accentColor : .white) {
                engine.toggleScreenShare()
            }
            roundButton(systemName: "phone.down.fill",
                        tint: .white, background: .red) {
                engine.hangUp()
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func roundButton(systemName: String, tint: Color,
                             background: Color = .black.opacity(0.6),
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(background))
        }.buttonStyle(.plain)
    }
}

/// Pont SwiftUI vers un renderer custom. stasel/WebRTC ne ship pas
/// RTCMTLNSVideoView dans la slice macOS du binaire, donc on implémente notre
/// propre renderer via AVSampleBufferDisplayLayer (le frame i420 est converti
/// en CMSampleBuffer puis enqueuel-é dans le display layer Metal).
struct RTCVideoTrackView: NSViewRepresentable {
    let track: RTCVideoTrack

    func makeNSView(context: Context) -> CrocVideoRendererView {
        let v = CrocVideoRendererView()
        track.add(v)
        return v
    }
    func updateNSView(_ nsView: CrocVideoRendererView, context: Context) {}
    static func dismantleNSView(_ nsView: CrocVideoRendererView, coordinator: ()) {
        // Track est retirée par ARC quand le caller la libère.
    }
}

/// Renderer macOS basé sur AVSampleBufferDisplayLayer. Conforme à
/// `RTCVideoRenderer` pour recevoir les frames depuis une RTCVideoTrack.
final class CrocVideoRendererView: NSView, RTCVideoRenderer {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var displaySize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(displayLayer)
    }
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    // MARK: - RTCVideoRenderer

    func setSize(_ size: CGSize) {
        DispatchQueue.main.async {
            self.displaySize = size
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        // Le buffer est natif en i420 (ou CVPixelBuffer pour la caméra macOS).
        // On ne traite que les CVPixelBuffer ici (cas courant via
        // RTCCameraVideoCapturer). Pour i420 distant, on convertit.
        if let pb = pixelBuffer(from: frame) {
            enqueue(pb, rotation: frame.rotation)
        }
    }

    private func pixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            return cvBuffer.pixelBuffer
        }
        // Frame i420 distante : on convertit en CVPixelBuffer NV12.
        if let i420 = (frame.buffer as? RTCI420Buffer) ?? (frame.buffer as? RTCMutableI420Buffer) {
            return CrocVideoRendererView.makeCVPixelBuffer(from: i420)
        }
        return nil
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation) {
        var fmt: CMVideoFormatDescription?
        let r = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
        guard r == noErr, let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                         presentationTimeStamp: CMTime(value: CMTimeValue(CFAbsoluteTimeGetCurrent() * 1000), timescale: 1000),
                                         decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let s = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sample)
        guard s == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async {
            self.displayLayer.enqueue(sample)
        }
    }

    /// Convertit un I420 buffer en CVPixelBuffer YUV. Approximation simple
    /// suffisante pour l'affichage (1 alloc par frame distant — à optimiser).
    private static func makeCVPixelBuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width), height = Int(i420.height)
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let r = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard r == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        // Y plane
        if let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            i420.dataY.withMemoryRebound(to: UInt8.self, capacity: Int(i420.strideY) * height) { yPtr in
                for row in 0..<height {
                    memcpy(yDst.advanced(by: row * yStride),
                           yPtr.advanced(by: row * Int(i420.strideY)),
                           width)
                }
            }
        }
        // UV interleaved plane (NV12).
        if let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let chromaH = height / 2
            i420.dataU.withMemoryRebound(to: UInt8.self, capacity: Int(i420.strideU) * chromaH) { uPtr in
                i420.dataV.withMemoryRebound(to: UInt8.self, capacity: Int(i420.strideV) * chromaH) { vPtr in
                    for row in 0..<chromaH {
                        let dstRow = uvDst.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
                        let uRow = uPtr.advanced(by: row * Int(i420.strideU))
                        let vRow = vPtr.advanced(by: row * Int(i420.strideV))
                        for col in 0..<(width / 2) {
                            dstRow[col * 2]     = uRow[col]
                            dstRow[col * 2 + 1] = vRow[col]
                        }
                    }
                }
            }
        }
        return pb
    }
}

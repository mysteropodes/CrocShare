import SwiftUI

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
            // TODO: RTCMTLVideoView pour la piste vidéo de ce participant.
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [.indigo.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            if !p.hasVideo {
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

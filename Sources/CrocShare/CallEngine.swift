import SwiftUI
import Combine
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MODULE  CallEngine (scaffolding)
//
// Architecture choisie : mesh WebRTC pour ≤ 4 participants, signaling via la
// liaison P2P existante (Hyperswarm). Pas de serveur SFU pour cette version —
// si on veut > 4 personnes plus tard, on intégrera LiveKit OSS (Apache 2.0).
//
// ── Dépendances proposées (à ajouter à Package.swift dans une PR séparée) ──
// • stasel/WebRTC (https://github.com/stasel/WebRTC) — wrapper Swift Package
//   autour de Google WebRTC. Apache 2.0. ~50 Mo de binaires.
// • ScreenCaptureKit (Apple, macOS 12.3+) pour capturer l'écran et l'injecter
//   dans une RTCVideoTrack.
// • AVFoundation pour caméra + micro.
//
// ── Permissions Info.plist à ajouter ─────────────────────────────────────
// • NSCameraUsageDescription — déjà présent
// • NSMicrophoneUsageDescription — déjà présent
// • NSScreenCaptureUsageDescription — à ajouter pour le screen share
//
// ── Flow de signaling (payloads P2P) ──────────────────────────────────────
// Tous les payloads passent par le bridge Hyperswarm existant (déjà chiffré
// E2E). On ajoute ces kinds dans P2PEngine.handlePayload :
//
//   call.invite  { callId, callerName, mode: "audio" | "video", participants }
//   call.accept  { callId, participantKey }
//   call.reject  { callId, reason }
//   call.offer   { callId, fromKey, toKey, sdp }
//   call.answer  { callId, fromKey, toKey, sdp }
//   call.ice     { callId, fromKey, toKey, candidate }
//   call.end     { callId, fromKey }
//
// En mesh : chaque pair établit une RTCPeerConnection avec chaque autre, en
// échangeant offer/answer/ice via les payloads ci-dessus.
//
// ── État ─────────────────────────────────────────────────────────────────
enum CallState: Equatable {
    case idle
    case outgoing(callId: UUID)          // j'ai appelé, j'attends une réponse
    case incoming(invite: CallInvite)    // on me sonne
    case connecting(callId: UUID)        // négociation SDP en cours
    case inCall(callId: UUID)            // connecté, audio/vidéo qui transite
    case ended(reason: String)
}

struct CallInvite: Equatable, Codable {
    var callId: UUID
    var fromKey: String
    var fromName: String
    var mode: CallMode
    var participants: [String]    // clés P2P invitées (initiateur compris)
}

enum CallMode: String, Codable { case audio, video }

struct CallParticipant: Identifiable, Equatable {
    let id: String                // clé P2P
    var displayName: String
    var isMe: Bool
    var hasVideo: Bool
    var isMuted: Bool
    var isScreenSharing: Bool
}

// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class CallEngine: ObservableObject {
    static let shared = CallEngine()

    @Published private(set) var state: CallState = .idle
    @Published private(set) var participants: [CallParticipant] = []
    @Published var isMicMuted: Bool = false
    @Published var isCameraOn: Bool = true
    @Published var isScreenSharing: Bool = false

    /// Référence faible vers P2PEngine pour signaling. Injectée au boot.
    weak var p2p: P2PEngine?

    private init() {}

    // MARK: - Cycle de vie d'appel

    /// Démarre un appel sortant vers les pairs indiqués (1 = direct, 2-3 = conf).
    /// Pour l'instant : envoie une `call.invite` et passe en state.outgoing.
    func startCall(mode: CallMode, with peers: [String]) {
        let callId = UUID()
        let invite = CallInvite(
            callId: callId,
            fromKey: p2p?.myPublicKey ?? "",
            fromName: p2p?.myName ?? "",
            mode: mode,
            participants: peers + [p2p?.myPublicKey ?? ""]
        )
        broadcast(.invite(invite), to: peers)
        state = .outgoing(callId: callId)
    }

    /// Accepte un appel entrant. Envoie `call.accept` à l'invitant et
    /// démarre la négociation WebRTC (TODO: brancher SDK).
    func accept(_ invite: CallInvite) {
        broadcast(.accept(callId: invite.callId, participantKey: p2p?.myPublicKey ?? ""),
                  to: [invite.fromKey])
        state = .connecting(callId: invite.callId)
        // TODO: créer RTCPeerConnection vers chaque participant et générer une offer.
    }

    /// Décline.
    func reject(_ invite: CallInvite, reason: String = "declined") {
        broadcast(.reject(callId: invite.callId, reason: reason), to: [invite.fromKey])
        state = .idle
    }

    /// Raccroche / quitte la conférence.
    func hangUp() {
        guard let callId = currentCallId else { return }
        let targets = participants.filter { !$0.isMe }.map(\.id)
        broadcast(.end(callId: callId), to: targets)
        participants = []
        state = .ended(reason: "hangup")
        // TODO: fermer les RTCPeerConnection.
    }

    /// Toggle screen share (ScreenCaptureKit).
    func toggleScreenShare() {
        isScreenSharing.toggle()
        // TODO: démarrer/arrêter ScreenCaptureKit SCContentSharingPicker +
        // injecter dans une RTCVideoTrack additionnelle.
    }

    private var currentCallId: UUID? {
        switch state {
        case .outgoing(let id), .connecting(let id), .inCall(let id): return id
        default: return nil
        }
    }

    // MARK: - Signaling P2P

    enum CallSignal {
        case invite(CallInvite)
        case accept(callId: UUID, participantKey: String)
        case reject(callId: UUID, reason: String)
        case offer(callId: UUID, sdp: String, toKey: String)
        case answer(callId: UUID, sdp: String, toKey: String)
        case ice(callId: UUID, candidate: String, toKey: String)
        case end(callId: UUID)

        var payloadKind: String {
            switch self {
            case .invite: return "call.invite"
            case .accept: return "call.accept"
            case .reject: return "call.reject"
            case .offer:  return "call.offer"
            case .answer: return "call.answer"
            case .ice:    return "call.ice"
            case .end:    return "call.end"
            }
        }
    }

    private func broadcast(_ signal: CallSignal, to keys: [String]) {
        guard let p2p else { return }
        let payload = signal.toPayload()
        for key in keys where key != p2p.myPublicKey && key != P2PEngine.botKey {
            // P2PEngine.deliverSignal (à exposer dans une PR séparée) ou via
            // un helper équivalent. Pour le scaffolding, on log seulement :
            print("call: → \(key.prefix(8)): \(signal.payloadKind)")
            _ = payload
        }
    }

    /// Appelé par P2PEngine quand un payload `call.*` arrive.
    func handleIncomingSignal(_ kind: String, payload: [String: Any], from key: String) {
        switch kind {
        case "call.invite":
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let invite = try? JSONDecoder().decode(CallInvite.self, from: data) else { return }
            state = .incoming(invite: invite)
        case "call.accept":
            // TODO: créer RTCPeerConnection + générer offer vers ce pair.
            break
        case "call.reject":
            if case .outgoing = state { state = .ended(reason: "rejected") }
        case "call.offer", "call.answer", "call.ice":
            // TODO: feed dans la RTCPeerConnection correspondante.
            break
        case "call.end":
            participants.removeAll { $0.id == key }
            if participants.allSatisfy(\.isMe) {
                state = .ended(reason: "remote hangup")
            }
        default:
            break
        }
    }
}

private extension CallEngine.CallSignal {
    func toPayload() -> [String: Any] {
        switch self {
        case .invite(let i):
            return ["k": payloadKind, "callId": i.callId.uuidString,
                    "fromKey": i.fromKey, "fromName": i.fromName,
                    "mode": i.mode.rawValue, "participants": i.participants]
        case .accept(let id, let key):
            return ["k": payloadKind, "callId": id.uuidString, "participantKey": key]
        case .reject(let id, let reason):
            return ["k": payloadKind, "callId": id.uuidString, "reason": reason]
        case .offer(let id, let sdp, let to):
            return ["k": payloadKind, "callId": id.uuidString, "sdp": sdp, "toKey": to]
        case .answer(let id, let sdp, let to):
            return ["k": payloadKind, "callId": id.uuidString, "sdp": sdp, "toKey": to]
        case .ice(let id, let cand, let to):
            return ["k": payloadKind, "callId": id.uuidString, "candidate": cand, "toKey": to]
        case .end(let id):
            return ["k": payloadKind, "callId": id.uuidString]
        }
    }
}

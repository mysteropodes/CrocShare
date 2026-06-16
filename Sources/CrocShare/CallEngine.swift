import SwiftUI
import Combine
import Foundation
import AVFoundation
import WebRTC

// ─────────────────────────────────────────────────────────────────────────────
// MODULE  CallEngine — appels P2P via WebRTC
//
// Architecture : mesh WebRTC (1 RTCPeerConnection par pair distant), signaling
// SDP+ICE transporté sur les payloads P2P "call.*" déjà routés par P2PEngine.
//
// • Audio : capture micro AVFoundation auto via WebRTC.
// • Vidéo : RTCCameraVideoCapturer sur la caméra par défaut.
// • Partage d'écran : ScreenCaptureKit (macOS 12.3+) → CMSampleBuffer feeding
//   un RTCVideoSource custom (non implémenté ici, hook prêt dans
//   `toggleScreenShare()`).
// • ICE servers : Google STUN par défaut, pas de TURN (relais nécessaire pour
//   les NAT symétriques — à ajouter quand on aura un coturn auto-hébergé).
// ─────────────────────────────────────────────────────────────────────────────

enum CallState: Equatable {
    case idle
    case outgoing(callId: UUID)
    case incoming(invite: CallInvite)
    case connecting(callId: UUID)
    case inCall(callId: UUID)
    case ended(reason: String)
}

struct CallInvite: Equatable, Codable {
    var callId: UUID
    var fromKey: String
    var fromName: String
    var mode: CallMode
    var participants: [String]
}

enum CallMode: String, Codable { case audio, video }

struct CallParticipant: Identifiable, Equatable {
    let id: String
    var displayName: String
    var isMe: Bool
    var hasVideo: Bool
    var isMuted: Bool
    var isScreenSharing: Bool
    /// Track vidéo distante associée (pour affichage RTCMTLVideoView).
    /// Non-equatable, on n'utilise que `id` côté ForEach.
    var videoTrack: RTCVideoTrack?

    static func == (lhs: CallParticipant, rhs: CallParticipant) -> Bool {
        lhs.id == rhs.id && lhs.hasVideo == rhs.hasVideo &&
        lhs.isMuted == rhs.isMuted && lhs.isScreenSharing == rhs.isScreenSharing &&
        lhs.displayName == rhs.displayName && lhs.isMe == rhs.isMe
    }
}

@MainActor
final class CallEngine: NSObject, ObservableObject {
    static let shared = CallEngine()

    @Published private(set) var state: CallState = .idle
    @Published private(set) var participants: [CallParticipant] = []
    @Published var isMicMuted: Bool = false { didSet { applyAudioMute() } }
    @Published var isCameraOn: Bool = true { didSet { applyVideoEnabled() } }
    @Published var isScreenSharing: Bool = false

    weak var p2p: P2PEngine?

    /// Une session WebRTC par pair distant.
    private var sessions: [String: WebRTCSession] = [:]

    /// Capture caméra + tracks locaux, créés à la demande au premier appel.
    private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoder = RTCDefaultVideoEncoderFactory()
        let videoDecoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoder, decoderFactory: videoDecoder)
    }()
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoSource: RTCVideoSource?
    private var videoCapturer: RTCCameraVideoCapturer?

    private override init() { super.init() }

    // MARK: - Cycle de vie d'appel

    func startCall(mode: CallMode, with peers: [String]) {
        let callId = UUID()
        prepareLocalMedia(video: mode == .video)
        appendMeParticipant(video: mode == .video)
        let invite = CallInvite(
            callId: callId, fromKey: p2p?.myPublicKey ?? "",
            fromName: p2p?.myName ?? "Moi", mode: mode,
            participants: peers + [p2p?.myPublicKey ?? ""])
        // Ouvre une session WebRTC vers chaque pair invité, et envoie l'offer.
        for key in peers {
            let session = ensureSession(for: key, mode: mode)
            session.createOffer { [weak self] sdp in
                guard let self, let sdp else { return }
                self.broadcast(.offer(callId: callId, sdp: sdp, toKey: key))
            }
        }
        broadcast(.invite(invite))
        state = .outgoing(callId: callId)
    }

    func accept(_ invite: CallInvite) {
        prepareLocalMedia(video: invite.mode == .video)
        appendMeParticipant(video: invite.mode == .video)
        // Préparer la session vers l'invitant ; il enverra son offer juste après.
        _ = ensureSession(for: invite.fromKey, mode: invite.mode)
        broadcast(.accept(callId: invite.callId, participantKey: p2p?.myPublicKey ?? ""))
        state = .connecting(callId: invite.callId)
    }

    func reject(_ invite: CallInvite, reason: String = "declined") {
        broadcast(.reject(callId: invite.callId, reason: reason))
        state = .idle
    }

    func hangUp() {
        guard let callId = currentCallId else { state = .idle; return }
        broadcast(.end(callId: callId))
        for session in sessions.values { session.close() }
        sessions.removeAll()
        videoCapturer?.stopCapture()
        videoCapturer = nil
        localAudioTrack = nil
        localVideoTrack = nil
        localVideoSource = nil
        participants = []
        state = .ended(reason: "hangup")
        // Reset après un court délai pour permettre une nouvelle session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.state = .idle
        }
    }

    func toggleScreenShare() {
        isScreenSharing.toggle()
        // TODO: ScreenCaptureKit → CMSampleBuffer → RTCVideoSource alimentant
        // une track de screenshare additionnelle, renégocier l'offer pour
        // l'ajouter aux sessions distantes.
    }

    private var currentCallId: UUID? {
        switch state {
        case .outgoing(let id), .connecting(let id), .inCall(let id): return id
        default: return nil
        }
    }

    // MARK: - Média local

    private func prepareLocalMedia(video: Bool) {
        if localAudioTrack == nil {
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let audioSource = factory.audioSource(with: constraints)
            localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        }
        if video && localVideoTrack == nil {
            let source = factory.videoSource()
            localVideoSource = source
            localVideoTrack = factory.videoTrack(with: source, trackId: "video0")
            let capturer = RTCCameraVideoCapturer(delegate: source)
            videoCapturer = capturer
            startCameraCapture()
        }
    }

    private func startCameraCapture() {
        guard let capturer = videoCapturer else { return }
        guard let device = RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.last ?? formats.first
        guard let format else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let fps = min(maxFps, 30)
        capturer.startCapture(with: device, format: format, fps: Int(fps)) { error in
            if let error { print("camera capture failed: \(error)") }
        }
    }

    private func applyAudioMute() {
        localAudioTrack?.isEnabled = !isMicMuted
        if var me = participants.firstIndex(where: { $0.isMe }) {
            participants[me].isMuted = isMicMuted
            _ = me
        }
    }
    private func applyVideoEnabled() {
        localVideoTrack?.isEnabled = isCameraOn
        if let i = participants.firstIndex(where: { $0.isMe }) {
            participants[i].hasVideo = isCameraOn
        }
    }

    private func appendMeParticipant(video: Bool) {
        let myKey = p2p?.myPublicKey ?? "me"
        guard !participants.contains(where: { $0.isMe }) else { return }
        participants.append(.init(
            id: myKey,
            displayName: p2p?.myName ?? "Moi",
            isMe: true, hasVideo: video, isMuted: false,
            isScreenSharing: false, videoTrack: localVideoTrack))
    }

    // MARK: - Sessions WebRTC

    private func ensureSession(for key: String, mode: CallMode) -> WebRTCSession {
        if let s = sessions[key] { return s }
        let session = WebRTCSession(remoteKey: key, factory: factory, mode: mode,
                                    audio: localAudioTrack, video: localVideoTrack)
        session.onIceCandidate = { [weak self] candidate in
            guard let self, let cid = self.currentCallId else { return }
            self.broadcast(.ice(callId: cid, candidate: candidate, toKey: key))
        }
        session.onRemoteVideoTrack = { [weak self] track in
            self?.attachRemoteVideoTrack(track, from: key)
        }
        session.onConnected = { [weak self] in
            guard let self, let cid = self.currentCallId else { return }
            self.state = .inCall(callId: cid)
        }
        sessions[key] = session
        return session
    }

    private func attachRemoteVideoTrack(_ track: RTCVideoTrack, from key: String) {
        if let i = participants.firstIndex(where: { $0.id == key }) {
            participants[i].videoTrack = track
            participants[i].hasVideo = true
        } else {
            let name = p2p?.name(for: key) ?? String(key.prefix(8))
            participants.append(.init(
                id: key, displayName: name, isMe: false,
                hasVideo: true, isMuted: false, isScreenSharing: false,
                videoTrack: track))
        }
    }

    // MARK: - Signaling (côté entrée)

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

    private func broadcast(_ signal: CallSignal) {
        guard let p2p else { return }
        let payload = signal.toPayload()
        // Cible : un pair précis si le signal en mentionne un, sinon tous les
        // participants connus (broadcast d'invite/end).
        let targets: [String]
        switch signal {
        case .offer(_, _, let to), .answer(_, _, let to), .ice(_, _, let to), .accept(_, let to):
            targets = [to]
        case .invite(let i): targets = i.participants.filter { $0 != p2p.myPublicKey }
        case .end, .reject:
            targets = participants.filter { !$0.isMe }.map(\.id)
        }
        for key in targets where key != p2p.myPublicKey && key != P2PEngine.botKey {
            Task { try? await p2p.bridgeRequest("peer.send", ["contactKey": key, "payload": payload]) }
        }
    }

    func handleIncomingSignal(_ kind: String, payload: [String: Any], from key: String) {
        switch kind {
        case "call.invite":
            // Décoder l'invite et basculer en state.incoming.
            guard
                let cidStr = payload["callId"] as? String, let cid = UUID(uuidString: cidStr),
                let fromKey = payload["fromKey"] as? String,
                let fromName = payload["fromName"] as? String,
                let modeRaw = payload["mode"] as? String, let mode = CallMode(rawValue: modeRaw)
            else { return }
            let participants = payload["participants"] as? [String] ?? [fromKey]
            let invite = CallInvite(callId: cid, fromKey: fromKey, fromName: fromName,
                                    mode: mode, participants: participants)
            state = .incoming(invite: invite)

        case "call.accept":
            // L'autre a accepté → on lui enverra notre offer dans createOffer
            // de la session (déjà en route depuis startCall).
            break

        case "call.reject":
            if case .outgoing = state { state = .ended(reason: "rejected") }

        case "call.offer":
            guard let sdpStr = payload["sdp"] as? String else { return }
            let sdp = RTCSessionDescription(type: .offer, sdp: sdpStr)
            let mode = currentMode()
            let session = ensureSession(for: key, mode: mode)
            session.handleRemoteOffer(sdp) { [weak self] answer in
                guard let self, let answer, let cid = self.currentCallId else { return }
                self.broadcast(.answer(callId: cid, sdp: answer, toKey: key))
            }

        case "call.answer":
            guard let sdpStr = payload["sdp"] as? String else { return }
            let sdp = RTCSessionDescription(type: .answer, sdp: sdpStr)
            sessions[key]?.handleRemoteAnswer(sdp)

        case "call.ice":
            guard let candStr = payload["candidate"] as? String,
                  let data = candStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sdp = obj["sdp"] as? String else { return }
            let mid = obj["sdpMid"] as? String
            let idx = (obj["sdpMLineIndex"] as? Int32) ?? 0
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: idx, sdpMid: mid)
            sessions[key]?.addRemoteCandidate(candidate)

        case "call.end":
            sessions[key]?.close()
            sessions.removeValue(forKey: key)
            participants.removeAll { $0.id == key }
            if participants.allSatisfy(\.isMe) { state = .ended(reason: "remote hangup") }

        default: break
        }
    }

    private func currentMode() -> CallMode {
        if case .incoming(let invite) = state { return invite.mode }
        return localVideoTrack != nil ? .video : .audio
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

// MARK: - WebRTCSession

/// Une RTCPeerConnection vers un pair distant donné. Encapsule le delegate
/// pour relayer les évènements (ICE, tracks distants, connexion).
final class WebRTCSession: NSObject, RTCPeerConnectionDelegate {
    let remoteKey: String
    private let mode: CallMode
    private let peerConnection: RTCPeerConnection
    private var localAudio: RTCAudioTrack?
    private var localVideo: RTCVideoTrack?

    var onIceCandidate: ((String) -> Void)?            // payload JSON encodé
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    var onConnected: (() -> Void)?

    init(remoteKey: String, factory: RTCPeerConnectionFactory, mode: CallMode,
         audio: RTCAudioTrack?, video: RTCVideoTrack?) {
        self.remoteKey = remoteKey
        self.mode = mode
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302",
                                     "stun:stun1.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        self.peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        self.localAudio = audio
        self.localVideo = video
        super.init()
        self.peerConnection.delegate = self
        // Ajoute les tracks locaux.
        if let audio { peerConnection.add(audio, streamIds: ["stream0"]) }
        if mode == .video, let video { peerConnection.add(video, streamIds: ["stream0"]) }
    }

    func createOffer(completion: @escaping (String?) -> Void) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": mode == .video ? "true" : "false"
            ], optionalConstraints: nil)
        peerConnection.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { completion(nil); return }
            self.peerConnection.setLocalDescription(sdp) { _ in
                completion(sdp.sdp)
            }
        }
    }

    func handleRemoteOffer(_ sdp: RTCSessionDescription, completion: @escaping (String?) -> Void) {
        peerConnection.setRemoteDescription(sdp) { [weak self] _ in
            guard let self else { completion(nil); return }
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                        "OfferToReceiveVideo": self.mode == .video ? "true" : "false"],
                optionalConstraints: nil)
            self.peerConnection.answer(for: constraints) { answer, _ in
                guard let answer else { completion(nil); return }
                self.peerConnection.setLocalDescription(answer) { _ in
                    completion(answer.sdp)
                }
            }
        }
    }

    func handleRemoteAnswer(_ sdp: RTCSessionDescription) {
        peerConnection.setRemoteDescription(sdp) { _ in }
    }

    func addRemoteCandidate(_ candidate: RTCIceCandidate) {
        peerConnection.add(candidate) { _ in }
    }

    func close() {
        peerConnection.close()
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            DispatchQueue.main.async { self.onConnected?() }
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Sérialise en JSON pour le transport via P2P payload.
        let obj: [String: Any] = [
            "sdp": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.onIceCandidate?(str) }
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            DispatchQueue.main.async { self.onRemoteVideoTrack?(track) }
        }
    }
}

import SwiftUI
import AVFoundation
import AppKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// Messages audio dans le chat : enregistreur (AVAudioRecorder) + bulle de
// lecture (AVPlayer). Format AAC dans un conteneur .m4a (compatible, léger,
// streamable).
// ─────────────────────────────────────────────────────────────────────────────

/// Wrapper enregistrement audio, observé par la SwiftUI view du composer.
/// L'API est intentionnellement minimale : démarrer / arrêter / annuler.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0    // 0…1 (RMS approximé)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var outputURL: URL?

    /// Démarre l'enregistrement vers un fichier temporaire. Retourne true si OK.
    func start() -> Bool {
        let dir = AudioRecorder.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voice-\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return false }
            recorder = r
            outputURL = url
            startedAt = Date()
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stoppe et conserve le fichier ; renvoie l'URL si succès.
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        timer?.invalidate(); timer = nil
        isRecording = false
        let url = outputURL
        recorder = nil
        return url
    }

    /// Stoppe et supprime le fichier.
    func cancel() {
        recorder?.stop()
        timer?.invalidate(); timer = nil
        isRecording = false
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        outputURL = nil
        elapsed = 0
        level = 0
    }

    private func tick() {
        if let started = startedAt { elapsed = Date().timeIntervalSince(started) }
        recorder?.updateMeters()
        // Power en dB (-160…0). Normaliser en 0…1.
        if let r = recorder {
            let p = r.averagePower(forChannel: 0)
            let norm = max(0, min(1, (p + 60) / 60))
            level = norm
        }
    }

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CrocShare/recordings", isDirectory: true)
    }
}

/// Bouton micro intégrable dans un composer : tient un AudioRecorder, affiche
/// minuterie + indicateur de niveau, et appelle `onFinish(URL)` à l'envoi.
struct AudioRecordingButton: View {
    var onFinish: (URL) -> Void
    @StateObject private var rec = AudioRecorder()

    var body: some View {
        HStack(spacing: 6) {
            if rec.isRecording {
                // Indicateur niveau (pulse).
                Circle().fill(Color.red).frame(width: 9, height: 9)
                    .scaleEffect(1.0 + CGFloat(rec.level) * 0.6)
                    .animation(.easeOut(duration: 0.12), value: rec.level)
                Text(timeString(rec.elapsed)).font(.caption.monospacedDigit())
                Button { rec.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Annuler")
                Button {
                    if let url = rec.stop() { onFinish(url) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .help("Envoyer")
            } else {
                Button {
                    _ = rec.start()
                } label: {
                    Image(systemName: "mic.fill").font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .help("Enregistrer un message audio")
            }
        }
        .padding(.horizontal, 4)
    }

    private func timeString(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bulle de lecture audio dans le chat. Lecteur compact avec progression.
struct AudioBubble: View {
    let url: URL
    @StateObject private var player = AudioPlayerEngine()
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).font(.system(size: 13, weight: .bold))
                }
                .frame(width: 32, height: 32)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                // Pseudo-waveform à partir de la progression.
                AudioProgressBar(progress: player.progress)
                    .frame(height: 22)
                HStack {
                    Text(timeString(player.current)).font(.caption2.monospacedDigit())
                    Spacer()
                    Text(timeString(player.duration)).font(.caption2.monospacedDigit())
                }.foregroundStyle(.secondary)
            }
            .frame(width: 200)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15)))
        .onAppear { player.load(url: url) }
        .onDisappear { player.pause() }
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Barre de progression style waveform (barres verticales pulse).
private struct AudioProgressBar: View {
    let progress: Double      // 0…1

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<26, id: \.self) { i in
                    let active = Double(i) / 26 <= progress
                    let h = 6 + CGFloat((i * 37) % 16)   // pseudo-aléatoire stable
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 3, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// Mini moteur AVPlayer dédié aux bulles audio.
@MainActor
final class AudioPlayerEngine: ObservableObject {
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    private var player: AVPlayer?
    private var timeObs: Any?

    var progress: Double { duration > 0 ? min(1, current / duration) : 0 }

    func load(url: URL) {
        let p = AVPlayer(url: url)
        player = p
        // Durée asynchrone.
        Task { [weak self] in
            if let dur = try? await p.currentItem?.asset.load(.duration), dur.isValid {
                await MainActor.run { self?.duration = dur.seconds }
            }
        }
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObs = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            self?.current = t.seconds
            if let d = self?.duration, d > 0, t.seconds >= d - 0.05 {
                self?.isPlaying = false
                p.seek(to: .zero)
            }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
    }
    func pause() {
        player?.pause()
        isPlaying = false
    }
    deinit {
        if let timeObs { player?.removeTimeObserver(timeObs) }
    }
}

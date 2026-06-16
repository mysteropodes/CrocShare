# CrocShare (macOS)

End-to-end encrypted **peer-to-peer** messaging and file sharing, with a
built-in video/image review workflow inspired by Frame.io. No central server.

> [!NOTE]
> CrocShare uses [Hyperswarm](https://github.com/holepunchto/hyperswarm)
> (Holepunch's P2P DHT) for discovery and transport, with
> [croc](https://github.com/schollz/croc) kept as a fallback. No account, no
> server to host. All required binaries are bundled.

## Overview

- 🔐 **P2P encrypted chat** per contact or per room: delivery receipts, emoji
  reactions, threaded replies, audio messages (.m4a), attachments (image,
  video, PDF, text, animated GIF, Rive), Slack-style multi-file bundles with
  one-click "download all".
- 📁 **Shared folders**: your local folder is visible to online contacts.
  Grid/list browser with thumbnails, sorting, per-file and per-folder info
  panel, right-click "Share with…" and visual share tracking.
- 🎬 **Frame.io-style video review**: large player, scrubber with markers,
  timestamped comments, threading, validation ✅, freehand annotation while
  paused. Comments sync between peers over P2P.
- 🖼 **Image review**: same workflow (comments + drawing) for images.
- ☁️ **Optional kDrive async relay**: when a contact is offline, messages can
  be deposited (encrypted with AES-GCM 256) on an Infomaniak kDrive folder and
  delivered when they come back.
- 🍎 **macOS vibrancy**, unified vertical sidebar, Quick Look–style sheets,
  built-in language switcher (FR/EN), automatic updates via Sparkle.

## Install

Grab the latest release: <https://github.com/mysteropodes/CrocShare/releases/latest>

Drag `CrocShare.app` into `/Applications`. If macOS blocks it on first launch
("unverified app"):

```sh
xattr -dr com.apple.quarantine /Applications/CrocShare.app
```

Subsequent updates go through Sparkle — no need to repeat.

## First run

1. Settings (⚙️) → **pick your shared folder** (and a download folder if you
   want to override the default `~/CrocShare`).
2. **Add a contact** (👤+): generate a code (`cs1-xxxx-xxxx-…`) and share it
   over any safe channel. Your contact pastes it on their side. The pair
   exchanges identities and a secret via Hyperswarm.
3. Once paired, the menu bar icon shows your contact's presence in real time.

## Review workflow (Frame.io-like)

- **Click** a video/image in the chat → fullscreen sheet with:
  - large video player (or enlarged image)
  - comments side panel: add at the current timecode, threading, clickable
    validation checkmark, inline editing
  - pencil button → **auto-pause** + color/thickness palette + freehand
    annotation
- **Double-click** the same thumbnail → opens in the default macOS app.

Comments sync automatically with peers when both sides are online (P2P payload
`vcomm`). Persistence is local (UserDefaults).

## Async kDrive relay (optional)

If you want messages to reach a contact **even when they're offline**, enable
it in Settings → kDrive Relay:

1. Create a Personal Access Token at [manager.infomaniak.com](https://manager.infomaniak.com)
   → your profile → **Tokens API** (⚠️ not "Application API" — that's for the
   OAuth2 redirect flow which isn't used here). Required scopes:
   - `drive:file:read` — list + download
   - `drive:file:write` — upload + delete after delivery

   *(If the UI only exposes `drive`, that's the parent scope and it covers
   both.)*
2. Note your Drive ID (URL: `kdrive.infomaniak.com/app/drive/<ID>/`) and the
   ID of a dedicated folder at the root (`crocshare-relay` for example).
3. Paste PAT + drive ID + folder ID into Settings and click "Test".

The PAT is stored in the **macOS Keychain**, never in plain text. Payloads
are encrypted client-side with AES-GCM 256 (HKDF-derived per-pair key) before
upload — the relay only sees opaque blobs. Adaptive polling, auto-cleanup
after 7 days by default.

## Streaming calls (work in progress)

A scaffolding for multi-party WebRTC calls + screen share is in place
(`CallEngine.swift`, `CallView.swift`). Wiring the actual WebRTC SDK
([stasel/WebRTC](https://github.com/stasel/WebRTC), Apache 2.0) plus
ScreenCaptureKit for screen sharing is the next step. Mesh topology for up to
4 peers; LiveKit OSS would be the path for larger conferences.

## Build from source

Requirements: Xcode 15+, [Node.js](https://nodejs.org) 20+ for the P2P companion
(downloaded by the script below), and an Apple Developer identity for a stable
signature (Sparkle requires it).

```sh
# 1. Fetch the native binaries (croc, Node, Sparkle, Rive).
./fetch-croc.sh
./fetch-runtime.sh

# 2. "Lab" build (ad-hoc signature, distinct bundle id, no auto-update).
LAB=1 ./make-app.sh
open "CrocShare Lab.app"

# 3. Signed production build (needs an Apple Developer identity).
export SIGN_IDENTITY="Apple Development: your.email@example.com (TEAMID)"
./make-app.sh
open CrocShare.app
```

For a full Sparkle release (EdDSA-signed zip + appcast), see `release.sh`.
You'll need the Sparkle private key in your Keychain.

## Architecture

Swift code lives in `Sources/CrocShare/`:

| Area | Main files |
|---|---|
| App entry | `CrocShareApp.swift` (Scene + menu bar) |
| Model | `Models.swift`, `Store.swift` |
| P2P engine | `P2PEngine.swift` + `+Bot`, `+Relay` extensions, `CoreBridge.swift` |
| Node companion | `core/*.js` (Hyperswarm, pairing, peers) |
| Main UI | `ContentView.swift` |
| Media | `MediaViews.swift` (video, Rive, PDF, text, animated GIF) |
| Video/image review | `VideoReview.swift` (scrubber, annotations, threading) |
| Audio | `AudioMessage.swift` |
| Lightbox | `Lightbox.swift` |
| kDrive relay | `KDriveRelay.swift`, `KDriveRelayUI.swift` |
| Vibrancy | `VisualEffectBackground.swift` |
| Updates | `UpdateManager.swift` (Sparkle) |
| Localization | `Localization.swift`, `Resources/{fr,en}.lproj/Localizable.strings` |
| Calls (scaffolding) | `CallEngine.swift`, `CallView.swift` |
| Legacy croc | `CrocService.swift`, `SyncEngine.swift`, `PairingService.swift`, `Channels.swift` |

### P2P protocol (direct chat)

On top of Hyperswarm (Noise + UDX, already end-to-end encrypted) the peers
exchange JSON payloads:

| `k` | Meaning |
|---|---|
| `msg` | Text message, optionally with `att` (attachment) |
| `ack` | Delivery receipt (`ids`) |
| `react` | Emoji reaction (toggle) |
| `del` | Delete-for-everyone of a message |
| `manifest` | List of shared files |
| `freq` | File request (`reqId`, `relPath`) |
| `chan` | Room definition |
| `profile` | Name + avatar |
| `vcomm` | Video/image comment (upsert/delete) |
| `call.*` | Call signaling (invite/accept/offer/answer/ice/end) |

Attachments are indexed by `relPath` in a `Chat/<scope>/` sub-folder of the
shared folder.

### Security

- Transport: Noise IK (Hyperswarm) end-to-end between peers, never in clear
  on the wire.
- Local storage: identity seed in the Keychain (`Keychain.swift`), contact
  secret too. No plain-text password on disk.
- kDrive relay: client-side AES-GCM 256, the server only sees opaque blobs +
  routing metadata (8-hex short keys).

## Known limitations

- No manual NAT-traversal signaling yet: if Hyperswarm can't punch, using a
  custom croc relay remains an option.
- P2P comment sync only reaches peers online at write time (planned: enqueue
  via kDrive relay).
- Windows / iOS / Android version: not in scope yet; the protocol is portable,
  the macOS UI isn't.

## Credits & licenses

- [croc](https://github.com/schollz/croc) — MIT, Zack Scholl
- [Hyperswarm](https://github.com/holepunchto/hyperswarm) — Apache 2.0, Holepunch Inc.
- [Sparkle](https://sparkle-project.org) — MIT
- [Rive](https://rive.app) runtime — MIT
- [stasel/WebRTC](https://github.com/stasel/WebRTC) (planned) — Apache 2.0

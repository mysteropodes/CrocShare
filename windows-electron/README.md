# CrocShare Windows (Electron)

Companion Windows client that talks to the same Hyperswarm P2P network as the
macOS SwiftUI app — Mac ↔ Windows interop out of the box, no protocol
divergence.

## Architecture

```
┌────────────────────────────────┐
│ Renderer (HTML/CSS/JS)         │  ← UI (sidebar + chat)
│ window.crocshare.* API         │
└────────────┬───────────────────┘
             │ IPC
┌────────────▼───────────────────┐
│ main.js (Electron main)        │
│ spawn core/index.js            │
└────────────┬───────────────────┘
             │ stdin/stdout JSON
┌────────────▼───────────────────┐
│ core/*.js (existing Node)      │  ← shared with macOS app
│ Hyperswarm, pairing, peers…    │
└────────────────────────────────┘
```

The `core/` folder is **not duplicated** here — it's the same one the macOS
app uses. `electron-builder` copies it into the installer via `extraResources`.

## Status

Early scaffolding. Implemented:
- ✅ Electron main process spawning the Node companion
- ✅ Renderer ↔ main IPC bridge (`window.crocshare.request/onEvent`)
- ✅ Sidebar with contacts + presence dots
- ✅ Chat view with text messages (compatible with the macOS `msg` payload)
- ✅ Pairing prompt (placeholder UI)
- ✅ electron-builder config for NSIS installer + GitHub publish

Not yet implemented (open work):
- ❌ Attachments (image/video/PDF/text/audio)
- ❌ Reactions, threads, channels
- ❌ Frame.io-style video/image review
- ❌ kDrive relay
- ❌ WebRTC calls (will use the browser-native `RTCPeerConnection` API — far
  simpler than the macOS path because Chromium ships WebRTC)
- ❌ Real React/Vue UI (current is vanilla JS, fine as a starter)

## Dev quickstart

Requires Node.js 20+.

```sh
cd windows-electron
npm install
# Make sure ../core has node_modules installed (run npm ci there once).
( cd ../core && npm ci )
npm run dev
```

The dev process opens DevTools by default.

## Build Windows installer

On Windows (or via cross-build):

```sh
npm run build:win
# → dist/CrocShare Setup x.y.z.exe
```

## Build macOS DMG (for parity testing)

```sh
npm run build:mac
```

## Auto-updates

Configured to use [electron-updater](https://www.electron.build/auto-update)
with GitHub releases. Set `GH_TOKEN` in your env and run `npm run release` to
publish.

## Communicate with the macOS app

The protocol JSON is identical. A macOS user and a Windows user pair using the
same `cs1-…` code workflow, then chat/share files transparently.

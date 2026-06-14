'use strict'
// Gestion des connexions persistantes par contact.
// Une connexion Hyperswarm = un flux Noise chiffré et authentifié : la clé
// publique distante (conn.remotePublicKey) est garantie par le protocole, donc
// on s'en sert directement pour identifier le contact (cf. §6 du brief).
const b4a = require('b4a')
const os = require('os')
const fs = require('fs')
const path = require('path')

const PING_INTERVAL = 25000 // keep-alive applicatif
const PING_TIMEOUT = 60000  // sans pong au-delà → on coupe, Hyperswarm reconnecte
const FILE_CHUNK = 256 * 1024 // taille de chunk pour le transfert de fichiers

class PeerManager {
  constructor ({ swarm, emit, log, isContact, onUnknownPeer, encodeKey, incomingDir }) {
    this.swarm = swarm
    this.emit = emit
    this.log = log
    this.isContact = isContact        // (keyHex) => bool
    this.onUnknownPeer = onUnknownPeer // (keyHex, conn, name, info) => void  (appairage)
    this.encodeKey = encodeKey         // (hex) => z32
    this.incomingDir = incomingDir     // dossier des fichiers reçus (temp)
    this.peers = new Map()             // keyHex -> { conn, name, direct, lastPong, timer }
    this.incoming = new Map()          // reqId -> { ws, tmpPath, relPath, size }
    this.displayName = os.hostname()
  }

  attach () {
    this.swarm.on('connection', (conn, info) => this._onConnection(conn, info))
  }

  setDisplayName (name) { if (name) this.displayName = name }

  _onConnection (conn, info) {
    const remoteKey = b4a.toString(conn.remotePublicKey, 'hex')
    conn.on('error', () => {})
    this._readFrames(conn, (msg) => this._onFrame(conn, remoteKey, info, msg))
    // Tout échange démarre par un "hello" (transporte juste le nom affiché ;
    // l'identité elle-même est déjà prouvée par Noise).
    this._write(conn, { type: 'hello', name: this.displayName })
    conn.once('close', () => this._onClose(remoteKey, conn))
  }

  _onFrame (conn, remoteKey, info, msg) {
    switch (msg && msg.type) {
      case 'hello':
        if (this.isContact(remoteKey)) this.register(remoteKey, conn, msg.name, info)
        else this.onUnknownPeer(remoteKey, conn, msg.name, info)
        break
      case '__ping':
        this._write(conn, { type: '__pong' })
        break
      case '__pong': {
        const p = this.peers.get(remoteKey)
        if (p) p.lastPong = Date.now()
        break
      }
      case 'app':
        this.emit('peer.message', { contactKey: this.encodeKey(remoteKey), payload: msg.payload })
        break
      case 'f-begin': this._fileBegin(remoteKey, msg); break
      case 'f-chunk': this._fileChunk(msg); break
      case 'f-end': this._fileEnd(remoteKey, msg); break
    }
  }

  // ---- Réception de fichier (écrit dans un temp, émet à la fin) ----

  _fileBegin (remoteKey, msg) {
    try { fs.mkdirSync(this.incomingDir, { recursive: true }) } catch {}
    const tmpPath = path.join(this.incomingDir, msg.reqId + '.part')
    try { fs.rmSync(tmpPath, { force: true }) } catch {}
    const ws = fs.createWriteStream(tmpPath)
    this.incoming.set(msg.reqId, { ws, tmpPath, relPath: msg.relPath, size: msg.size || 0 })
  }

  _fileChunk (msg) {
    const inc = this.incoming.get(msg.reqId)
    if (inc && msg.b64) inc.ws.write(b4a.from(msg.b64, 'base64'))
  }

  _fileEnd (remoteKey, msg) {
    const inc = this.incoming.get(msg.reqId)
    if (!inc) return
    this.incoming.delete(msg.reqId)
    inc.ws.end(() => {
      this.emit('peer.fileReceived', {
        contactKey: this.encodeKey(remoteKey),
        reqId: msg.reqId, relPath: inc.relPath, tmpPath: inc.tmpPath, size: inc.size
      })
    })
  }

  // ---- Envoi de fichier (streaming + backpressure) ----

  sendFile (remoteKey, reqId, relPath, absPath) {
    const peer = this.peers.get(remoteKey)
    if (!peer) { this.emit('peer.fileSendFailed', { reqId, reason: 'offline' }); return }
    let size = 0
    try { size = fs.statSync(absPath).size } catch {
      this.emit('peer.fileSendFailed', { reqId, reason: 'not-found' }); return
    }
    this._write(peer.conn, { type: 'f-begin', reqId, relPath, size })
    const rs = fs.createReadStream(absPath, { highWaterMark: FILE_CHUNK })
    rs.on('data', (chunk) => {
      const ok = this._write(peer.conn, { type: 'f-chunk', reqId, b64: b4a.toString(chunk, 'base64') })
      if (ok === false) { rs.pause(); peer.conn.once('drain', () => rs.resume()) }
    })
    rs.on('end', () => {
      this._write(peer.conn, { type: 'f-end', reqId, relPath })
      this.emit('peer.fileSent', { reqId, contactKey: this.encodeKey(remoteKey) })
    })
    rs.on('error', () => this.emit('peer.fileSendFailed', { reqId, reason: 'read-error' }))
  }

  // Promeut une connexion en connexion-contact active (présence + keep-alive).
  register (remoteKey, conn, name, info) {
    const existing = this.peers.get(remoteKey)
    if (existing) {
      if (existing.conn === conn) return
      // Doublon (les deux côtés ont pu initier) : garde la nouvelle.
      if (existing.timer) clearInterval(existing.timer)
      try { existing.conn.destroy() } catch {}
    }
    const direct = !!(conn.rawStream && conn.rawStream.remoteHost)
    const peer = { conn, name: name || null, direct, lastPong: Date.now(), timer: null }
    peer.timer = setInterval(() => {
      if (Date.now() - peer.lastPong > PING_TIMEOUT) { try { conn.destroy() } catch {} ; return }
      this._write(conn, { type: '__ping' })
    }, PING_INTERVAL)
    this.peers.set(remoteKey, peer)
    this.emit('peer.connected', { contactKey: this.encodeKey(remoteKey), direct, name: name || null })
  }

  _onClose (remoteKey, conn) {
    const peer = this.peers.get(remoteKey)
    if (peer && peer.conn === conn) {
      if (peer.timer) clearInterval(peer.timer)
      this.peers.delete(remoteKey)
      this.emit('peer.disconnected', { contactKey: this.encodeKey(remoteKey), reason: 'closed' })
    }
  }

  send (remoteKey, payload) {
    const peer = this.peers.get(remoteKey)
    if (!peer) return false
    this._write(peer.conn, { type: 'app', payload })
    return true
  }

  disconnect (remoteKey) {
    const peer = this.peers.get(remoteKey)
    if (peer) { if (peer.timer) clearInterval(peer.timer); try { peer.conn.destroy() } catch {} ; this.peers.delete(remoteKey) }
  }

  status () {
    const peers = []
    for (const [key, p] of this.peers) {
      peers.push({ key: this.encodeKey(key), state: 'connected', direct: p.direct, rttMs: null })
    }
    return peers
  }

  _write (conn, obj) {
    try { return conn.write(b4a.from(JSON.stringify(obj) + '\n')) } catch { return false }
  }

  // Framing NDJSON sur le flux d'octets : on découpe sur 0x0a (jamais présent
  // à l'intérieur d'une séquence UTF-8 multi-octets, donc sûr au niveau octet).
  _readFrames (conn, onMsg) {
    let chunks = []
    conn.on('data', (data) => {
      let start = 0
      for (let i = 0; i < data.length; i++) {
        if (data[i] === 0x0a) {
          chunks.push(data.subarray(start, i))
          const line = b4a.toString(b4a.concat(chunks))
          chunks = []
          start = i + 1
          if (line.length) { try { onMsg(JSON.parse(line)) } catch {} }
        }
      }
      if (start < data.length) chunks.push(data.subarray(start))
    })
  }
}

module.exports = { PeerManager }

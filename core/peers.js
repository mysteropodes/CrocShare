'use strict'
// Gestion des connexions persistantes par contact.
// Une connexion Hyperswarm = un flux Noise chiffré et authentifié : la clé
// publique distante (conn.remotePublicKey) est garantie par le protocole, donc
// on s'en sert directement pour identifier le contact (cf. §6 du brief).
const b4a = require('b4a')
const os = require('os')

const PING_INTERVAL = 25000 // keep-alive applicatif
const PING_TIMEOUT = 60000  // sans pong au-delà → on coupe, Hyperswarm reconnecte

class PeerManager {
  constructor ({ swarm, emit, log, isContact, onUnknownPeer, encodeKey }) {
    this.swarm = swarm
    this.emit = emit
    this.log = log
    this.isContact = isContact        // (keyHex) => bool
    this.onUnknownPeer = onUnknownPeer // (keyHex, conn, name, info) => void  (appairage)
    this.encodeKey = encodeKey         // (hex) => z32
    this.peers = new Map()             // keyHex -> { conn, name, direct, lastPong, timer }
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
    }
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
    this.emit('peer.connected', { contactKey: this.encodeKey(remoteKey), direct })
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
    try { conn.write(b4a.from(JSON.stringify(obj) + '\n')) } catch {}
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

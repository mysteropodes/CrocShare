'use strict'
// Appairage via topic DHT éphémère dérivé du code d'invitation (cf. §6).
// L'hôte (createInvite) attend ; l'invité (acceptInvite) rejoint et la
// connexion Hyperswarm chiffrée s'établit sur le topic.
const b4a = require('b4a')
const identity = require('./identity')
const { RpcError } = require('./rpc')

const INVITE_TTL = 15 * 60 * 1000 // validité du code
const ACCEPT_TIMEOUT = 120 * 1000 // attente côté invité (DHT publique à froid = lent)

class PairingManager {
  constructor ({ swarm, log }) {
    this.swarm = swarm
    this.log = log
    this.active = new Map() // topicHex -> { topic, timer, resolve }
  }

  async createInvite () {
    const secret = identity.generateSeed().subarray(0, 16)
    const topic = identity.pairingTopic(secret)
    const topicHex = identity.hex(topic)
    const discovery = this.swarm.join(topic, { server: true, client: true })
    await discovery.flushed().catch(() => {})
    const timer = setTimeout(() => this._end(topicHex), INVITE_TTL)
    this.active.set(topicHex, { topic, timer, resolve: null })
    return { invite: 'cs1-' + identity.encodeKey(secret) }
  }

  async acceptInvite (code) {
    if (!code || typeof code !== 'string' || !code.startsWith('cs1-')) {
      throw new RpcError('INVALID_INVITE', 'Format de code invalide')
    }
    let secret
    try { secret = identity.decodeKey(code.slice(4)) } catch { throw new RpcError('INVALID_INVITE', 'Code illisible') }
    if (secret.length !== 16) throw new RpcError('INVALID_INVITE', 'Code invalide')
    const topic = identity.pairingTopic(secret)
    const topicHex = identity.hex(topic)
    const discovery = this.swarm.join(topic, { server: true, client: true })
    await discovery.flushed().catch(() => {})
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._end(topicHex)
        reject(new RpcError('PEER_UNREACHABLE', "Aucune reponse a l'invitation"))
      }, ACCEPT_TIMEOUT)
      this.active.set(topicHex, { topic, timer, resolve })
    })
  }

  isPairing () { return this.active.size > 0 }

  // Appelé par l'orchestrateur quand l'appairage aboutit (peer inconnu connecté).
  resolveAccept (contactKey, name) {
    for (const entry of this.active.values()) {
      if (entry.resolve) { clearTimeout(entry.timer); const r = entry.resolve; entry.resolve = null; r({ contactKey, name: name || null }) }
    }
  }

  endAll () {
    for (const topicHex of [...this.active.keys()]) this._end(topicHex)
  }

  _end (topicHex) {
    const entry = this.active.get(topicHex)
    if (!entry) return
    clearTimeout(entry.timer)
    try { this.swarm.leave(entry.topic) } catch {}
    this.active.delete(topicHex)
  }
}

module.exports = { PairingManager }

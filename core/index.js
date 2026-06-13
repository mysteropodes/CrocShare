'use strict'
// crocshare-core — orchestrateur du compagnon P2P (Phase 1).
// Boot : boucle RPC stdio. Toute la logique réseau vit ici et dans les managers.
// Frontière stricte : aucune UI, aucun Trousseau, aucune clé privée en clair sur disque.
const path = require('path')
const fs = require('fs').promises // NOTE Bare: remplacer par bare-fs lors de la bascule
const b4a = require('b4a')

const { createTransport, emit, log, RpcError } = require('./rpc')
const identity = require('./identity')
const { createSwarm } = require('./swarm')
const { PeerManager } = require('./peers')
const { PairingManager } = require('./pairing')

const core = {
  keyPair: null,
  selfKeyHex: null,
  storagePath: null,
  swarm: null,
  peers: null,
  pairing: null,
  contacts: new Map(),     // keyHex -> { key: hex, addedAt }
  joinedTopics: new Map(), // topicHex -> discovery
  displayName: require('os').hostname()
}

// ---- Persistance des contacts (clés publiques uniquement, rien de secret) ----

function contactsFile () { return path.join(core.storagePath, 'contacts.json') }

async function loadContacts () {
  try {
    const raw = await fs.readFile(contactsFile(), 'utf-8')
    const arr = JSON.parse(raw)
    const m = new Map()
    for (const c of arr) m.set(c.key, c)
    return m
  } catch { return new Map() }
}

async function saveContacts () {
  try {
    await fs.writeFile(contactsFile(), JSON.stringify([...core.contacts.values()], null, 2))
  } catch (e) { log('warn', 'saveContacts failed', { e: String(e) }) }
}

function addContact (remoteKeyHex) {
  if (!core.contacts.has(remoteKeyHex)) {
    core.contacts.set(remoteKeyHex, { key: remoteKeyHex, addedAt: Date.now() })
    saveContacts()
  }
}

// ---- Topics ----

function joinPeerTopic (remoteKeyHex) {
  const topic = identity.peerTopic(core.keyPair.publicKey, b4a.from(remoteKeyHex, 'hex'))
  const topicHex = identity.hex(topic)
  if (core.joinedTopics.has(topicHex)) return
  core.joinedTopics.set(topicHex, core.swarm.join(topic, { server: true, client: true }))
}

function leavePeerTopic (remoteKeyHex) {
  const topic = identity.peerTopic(core.keyPair.publicKey, b4a.from(remoteKeyHex, 'hex'))
  const topicHex = identity.hex(topic)
  if (core.joinedTopics.has(topicHex)) {
    try { core.swarm.leave(topic) } catch {}
    core.joinedTopics.delete(topicHex)
  }
}

async function connectAll () {
  for (const c of core.contacts.values()) joinPeerTopic(c.key)
  if (core.swarm) await core.swarm.flush().catch(() => {})
}

// Appairage : un peer inconnu se connecte alors qu'une invitation est active.
function onUnknownPeer (remoteKey, conn, name, info) {
  if (!core.pairing.isPairing()) { try { conn.destroy() } catch {} ; return }
  addContact(remoteKey)
  const ckey = identity.encodeKey(b4a.from(remoteKey, 'hex'))
  emit('pairing.peerJoined', { contactKey: ckey })
  core.pairing.resolveAccept(ckey, name)   // résout acceptInvite côté invité
  core.peers.register(remoteKey, conn, name, info)
  core.pairing.endAll()
  joinPeerTopic(remoteKey)
}

// ---- Méthodes RPC ----

const methods = {
  async init (params) {
    if (core.swarm) return { publicKey: identity.encodeKey(core.keyPair.publicKey) }
    if (!params.storagePath) throw new RpcError('INTERNAL', 'storagePath requis')
    core.storagePath = params.storagePath
    await fs.mkdir(core.storagePath, { recursive: true })

    let generated = false
    let seed
    if (params.seed) {
      seed = b4a.from(params.seed, 'hex')
    } else {
      seed = identity.generateSeed()
      generated = true
    }
    core.keyPair = identity.deriveKeyPair(seed)
    core.selfKeyHex = identity.hex(core.keyPair.publicKey)
    core.contacts = await loadContacts()

    core.swarm = createSwarm(core.keyPair, { bootstrap: params.bootstrap })
    core.swarm.on('error', (e) => emit('core.error', { code: 'INTERNAL', message: String(e), fatal: false }))

    core.peers = new PeerManager({
      swarm: core.swarm,
      emit,
      log,
      isContact: (keyHex) => core.contacts.has(keyHex),
      onUnknownPeer,
      encodeKey: (keyHex) => identity.encodeKey(b4a.from(keyHex, 'hex'))
    })
    core.peers.setDisplayName(core.displayName)
    core.peers.attach()

    core.pairing = new PairingManager({ swarm: core.swarm, log })

    await connectAll()
    const publicKey = identity.encodeKey(core.keyPair.publicKey)
    emit('core.ready', { publicKey })
    const res = { publicKey }
    if (generated) res.seed = identity.hex(seed) // Swift le stocke au Trousseau
    return res
  },

  async shutdown () {
    try { if (core.swarm) await core.swarm.destroy() } catch {}
    setTimeout(() => process.exit(0), 50)
    return {}
  },

  async 'pairing.createInvite' () {
    requireReady()
    return core.pairing.createInvite()
  },

  async 'pairing.acceptInvite' (params) {
    requireReady()
    return core.pairing.acceptInvite(params.invite)
  },

  async 'contacts.list' () {
    requireReady()
    const contacts = [...core.contacts.values()].map((c) => ({
      key: identity.encodeKey(b4a.from(c.key, 'hex')),
      addedAt: c.addedAt
    }))
    return { contacts }
  },

  async 'contacts.remove' (params) {
    requireReady()
    const keyHex = identity.hex(identity.decodeKey(params.contactKey))
    core.peers.disconnect(keyHex)
    leavePeerTopic(keyHex)
    core.contacts.delete(keyHex)
    await saveContacts()
    return {}
  },

  async 'swarm.connectAll' () {
    requireReady()
    await connectAll()
    return {}
  },

  async 'peer.send' (params) {
    requireReady()
    const keyHex = identity.hex(identity.decodeKey(params.contactKey))
    const delivered = core.peers.send(keyHex, params.payload)
    return { delivered }
  },

  async status () {
    return {
      dht: !!core.swarm,
      peers: core.peers ? core.peers.status() : []
    }
  }
}

function requireReady () {
  if (!core.swarm) throw new RpcError('NOT_INITIALIZED', 'Core non initialise')
}

// ---- Boot ----

createTransport(async (method, params) => {
  const fn = methods[method]
  if (!fn) throw new RpcError('INTERNAL', 'Methode inconnue: ' + method)
  return fn(params)
})

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    try { if (core.swarm) await core.swarm.destroy() } catch {}
    process.exit(0)
  })
}

log('info', 'crocshare-core started', { pid: process.pid })

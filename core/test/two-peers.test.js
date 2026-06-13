'use strict'
// Deux processus core distincts s'appairent via un code cs1-… puis échangent
// un ping/echo applicatif. DHT locale (testnet) → test hors-ligne et rapide.
const test = require('brittle')
const createTestnet = require('hyperdht/testnet')
const os = require('os')
const path = require('path')
const fs = require('fs')
const { CoreClient } = require('./helper')

function tmpDir (name) {
  const d = path.join(os.tmpdir(), 'crocshare-test', name + '-' + Date.now())
  fs.mkdirSync(d, { recursive: true })
  return d
}

test('appairage cs1- + ping/echo entre deux cores', async (t) => {
  const testnet = await createTestnet(3)
  t.teardown(() => testnet.destroy())
  const bootstrap = testnet.bootstrap

  const a = new CoreClient(tmpDir('peerA'), 'A')
  const b = new CoreClient(tmpDir('peerB'), 'B')
  a.start(); b.start()
  t.teardown(() => a.stop())
  t.teardown(() => b.stop())

  const ra = await a.request('init', { storagePath: a.storagePath, bootstrap, displayName: 'Alice' })
  const rb = await b.request('init', { storagePath: b.storagePath, bootstrap, displayName: 'Bob' })
  const aKey = ra.publicKey
  const bKey = rb.publicKey
  t.ok(aKey && bKey, 'deux identités générées')

  const aConnected = a.once('peer.connected')
  const bConnected = b.once('peer.connected')

  const { invite } = await a.request('pairing.createInvite')
  t.ok(invite.startsWith('cs1-'), 'code au format cs1-')

  const accepted = await b.request('pairing.acceptInvite', { invite })
  t.is(accepted.contactKey, aKey, "l'invité reçoit la clé de l'hôte")

  const aSees = await aConnected
  const bSees = await bConnected
  t.pass('connexion persistante établie des deux côtés')
  t.is(aSees.name, 'Bob', "A voit le nom de B")
  t.is(bSees.name, 'Alice', "B voit le nom de A")

  // B renvoie un echo à chaque ping reçu.
  b.on('peer.message', ({ contactKey, payload }) => {
    if (payload && payload.t === 'ping') {
      b.request('peer.send', { contactKey, payload: { t: 'echo', ts: payload.ts } })
    }
  })

  const echo = a.once('peer.message')
  const ts = Date.now()
  const sent = await a.request('peer.send', { contactKey: bKey, payload: { t: 'ping', ts } })
  t.ok(sent.delivered, 'ping délivré')

  const got = await echo
  t.is(got.payload.t, 'echo', 'echo reçu par l\'émetteur')
  t.is(got.payload.ts, ts, 'corrélation du round-trip')
  const rtt = Date.now() - ts
  t.ok(rtt < 5000, 'round-trip < 5s (' + rtt + 'ms)')

  // Les contacts sont persistés des deux côtés.
  const la = await a.request('contacts.list')
  t.is(la.contacts.length, 1, 'A a 1 contact')
  t.is(la.contacts[0].key, bKey, 'A connaît B')
})

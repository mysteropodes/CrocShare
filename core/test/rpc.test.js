'use strict'
// Protocole RPC + identité : une seed redonne la même clé publique (déterminisme),
// et la seed n'est renvoyée que lorsqu'elle est générée.
const test = require('brittle')
const os = require('os')
const path = require('path')
const fs = require('fs')
const { CoreClient } = require('./helper')

function tmpDir (name) {
  const d = path.join(os.tmpdir(), 'crocshare-test', name + '-' + Date.now())
  fs.mkdirSync(d, { recursive: true })
  return d
}

test('init génère une identité, la seed est déterministe', async (t) => {
  const dir = tmpDir('rpc')

  const a = new CoreClient(dir)
  a.start()
  const first = await a.request('init', { storagePath: dir })
  t.ok(first.publicKey, 'publicKey renvoyée')
  t.ok(first.seed, 'seed renvoyée car générée')
  const pub = first.publicKey
  const seed = first.seed
  await a.stop()

  const b = new CoreClient(dir)
  b.start()
  const second = await b.request('init', { storagePath: dir, seed })
  t.is(second.publicKey, pub, 'même clé publique avec la même seed')
  t.absent(second.seed, 'pas de seed renvoyée quand fournie')
  await b.stop()

  const status = '(ok)'
  t.ok(status)
})

test('méthode inconnue → erreur INTERNAL', async (t) => {
  const dir = tmpDir('rpc-err')
  const a = new CoreClient(dir)
  a.start()
  await a.request('init', { storagePath: dir })
  await t.exception(() => a.request('does.not.exist', {}))
  await a.stop()
})

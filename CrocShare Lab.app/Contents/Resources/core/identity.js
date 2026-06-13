'use strict'
// Identité cryptographique et dérivation des topics DHT.
// Seule logique "maison" du Core : tout le reste délègue à hypercore-crypto.
const crypto = require('hypercore-crypto')
const b4a = require('b4a')
const z32 = require('z32')

// Seed = 32 octets aléatoires, persistée par Swift dans le Trousseau (jamais ici).
function generateSeed () { return crypto.randomBytes(32) }

// Paire Ed25519 déterministe à partir de la seed.
function deriveKeyPair (seed) { return crypto.keyPair(seed) }

function hex (buf) { return b4a.toString(buf, 'hex') }
function fromHex (s) { return b4a.from(s, 'hex') }

// Clés publiques exposées à l'UI en z32 (lisible, compact).
function encodeKey (buf) { return z32.encode(b4a.from(buf)) }
function decodeKey (s) { return z32.decode(s) }

// Topic éphémère d'appairage, dérivé du secret d'invitation (16 octets).
function pairingTopic (secret) {
  return crypto.hash(b4a.concat([b4a.from('crocshare-pairing:'), b4a.from(secret)]))
}

// Topic stable d'un couple de contacts : symétrique (tri des clés) → les deux
// dérivent le même topic et se retrouvent via la DHT à chaque démarrage.
function peerTopic (pubA, pubB) {
  const a = b4a.from(pubA)
  const b = b4a.from(pubB)
  const [lo, hi] = b4a.compare(a, b) <= 0 ? [a, b] : [b, a]
  return crypto.hash(b4a.concat([b4a.from('crocshare-peer:'), lo, hi]))
}

module.exports = { generateSeed, deriveKeyPair, hex, fromHex, encodeKey, decodeKey, pairingTopic, peerTopic }

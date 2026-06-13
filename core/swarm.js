'use strict'
// Fabrique Hyperswarm. `bootstrap` n'est passé qu'en test (testnet local) ;
// en production, Hyperswarm utilise la DHT publique Holepunch.
const Hyperswarm = require('hyperswarm')

function createSwarm (keyPair, opts = {}) {
  const cfg = { keyPair }
  if (opts.bootstrap) cfg.bootstrap = opts.bootstrap
  return new Hyperswarm(cfg)
}

module.exports = { createSwarm }

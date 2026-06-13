'use strict'
// Transport JSON-RPC sur stdio (NDJSON) entre Swift et le Core.
// stdin  : requêtes Swift → Core (une ligne JSON par message)
// stdout : réponses + événements Core → Swift
// stderr : logs structurés uniquement (jamais de réponse RPC)
const readline = require('readline')

function createTransport (onRequest) {
  const rl = readline.createInterface({ input: process.stdin })
  rl.on('line', async (raw) => {
    const line = raw.trim()
    if (!line) return
    let msg
    try { msg = JSON.parse(line) } catch { return }
    if (msg.method == null || msg.id == null) return
    try {
      const result = await onRequest(msg.method, msg.params || {})
      send({ id: msg.id, result: result || {} })
    } catch (err) {
      send({ id: msg.id, error: { code: err.code || 'INTERNAL', message: err.message || String(err) } })
    }
  })
  return rl
}

function send (obj) {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

// Événement non sollicité (pas d'id) — consommé par le Store côté Swift.
function emit (event, params) {
  send({ event, params: params || {} })
}

function log (level, msg, ctx) {
  process.stderr.write(JSON.stringify({ ts: Date.now(), level, msg, ctx: ctx || {} }) + '\n')
}

// Erreur RPC avec code stable (cf. §8 du brief).
class RpcError extends Error {
  constructor (code, message) { super(message); this.code = code }
}

module.exports = { createTransport, send, emit, log, RpcError }

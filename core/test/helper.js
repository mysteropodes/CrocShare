'use strict'
// Pilote un processus crocshare-core via son protocole stdio (comme le fera Swift).
const { spawn } = require('child_process')
const path = require('path')
const readline = require('readline')

class CoreClient {
  constructor (storagePath, label) {
    this.storagePath = storagePath
    this.label = label || 'core'
    this.proc = null
    this.nextId = 1
    this.pending = new Map()
    this.listeners = new Map() // event -> Set<fn>
  }

  start () {
    this.proc = spawn(process.execPath, [path.join(__dirname, '..', 'index.js')], {
      stdio: ['pipe', 'pipe', 'pipe']
    })
    const rl = readline.createInterface({ input: this.proc.stdout })
    rl.on('line', (line) => {
      let msg
      try { msg = JSON.parse(line) } catch { return }
      if (msg.id != null && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id)
        this.pending.delete(msg.id)
        if (msg.error) reject(Object.assign(new Error(msg.error.message), { code: msg.error.code }))
        else resolve(msg.result)
      } else if (msg.event) {
        const set = this.listeners.get(msg.event)
        if (set) for (const fn of set) fn(msg.params)
      }
    })
    // Logs du Core sur stderr (utile en debug ; silencieux par défaut).
    if (process.env.CORE_DEBUG) this.proc.stderr.pipe(process.stderr)
    else this.proc.stderr.resume()
  }

  request (method, params = {}, timeout = 50000) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error('timeout ' + method))
      }, timeout)
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(t); resolve(v) },
        reject: (e) => { clearTimeout(t); reject(e) }
      })
      this.proc.stdin.write(JSON.stringify({ id, method, params }) + '\n')
    })
  }

  on (event, fn) {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set())
    this.listeners.get(event).add(fn)
  }

  once (event) {
    return new Promise((resolve) => {
      const fn = (params) => { this.listeners.get(event).delete(fn); resolve(params) }
      this.on(event, fn)
    })
  }

  async stop () {
    try { await this.request('shutdown', {}, 3000) } catch {}
    if (this.proc && !this.proc.killed) this.proc.kill('SIGKILL')
  }
}

module.exports = { CoreClient }

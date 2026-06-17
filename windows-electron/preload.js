// Bridge sécurisé entre le renderer (web) et le main process.
// Le renderer accède à `window.crocshare.*` ; pas d'accès direct à Node ou
// au file system.

const { contextBridge, ipcRenderer } = require('electron');

const eventCallbacks = new Set();

ipcRenderer.on('p2p:event', (_e, evt) => {
  for (const fn of eventCallbacks) {
    try { fn(evt); } catch (e) { console.error('event callback:', e); }
  }
});

contextBridge.exposeInMainWorld('crocshare', {
  // Appel RPC vers le compagnon Node (Hyperswarm).
  request: (kind, params) => ipcRenderer.invoke('p2p:request', kind, params),

  // Abonnement aux events poussés par le core (peer.connected, peer.message…).
  onEvent: (callback) => {
    eventCallbacks.add(callback);
    return () => eventCallbacks.delete(callback);
  },

  // Ouvre un lien dans le navigateur par défaut.
  openExternal: (url) => ipcRenderer.invoke('app:openExternal', url),

  // Infos plateforme.
  version: () => ipcRenderer.invoke('app:version'),
  platform: () => ipcRenderer.invoke('app:platform'),
  storagePath: () => ipcRenderer.invoke('app:storagePath'),
  homePath: () => ipcRenderer.invoke('app:home'),

  // Config locale (équivalent AppConfig Mac).
  config: {
    get: () => ipcRenderer.invoke('config:get'),
    set: (obj) => ipcRenderer.invoke('config:set', obj),
  },

  // Token kDrive (chiffré via safeStorage).
  pat: {
    get: () => ipcRenderer.invoke('pat:get'),
    set: (v) => ipcRenderer.invoke('pat:set', v),
    clear: () => ipcRenderer.invoke('pat:clear'),
  },

  // Dialogues système.
  dialog: {
    pickFolder: () => ipcRenderer.invoke('dialog:pickFolder'),
    pickFile: (options) => ipcRenderer.invoke('dialog:pickFile', options),
  },

  // Relance l'app (changement de langue).
  relaunch: () => ipcRenderer.invoke('app:relaunch'),

  // Test connexion kDrive.
  kdrive: {
    test: (params) => ipcRenderer.invoke('kdrive:test', params),
  },

  // File helpers (pour attachments).
  fileStat: (filePath) => ipcRenderer.invoke('file:stat', filePath),
  fileUrl: (filePath) => ipcRenderer.invoke('file:url', filePath),
  saveTempBuffer: (name, buffer) => ipcRenderer.invoke('file:saveTempBuffer', name, buffer),
});

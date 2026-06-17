// CrocShare Windows — process principal Electron.
//
// Réutilise le compagnon Node.js existant (core/*.js du repo macOS) en le
// spawnant comme child_process. La communication suit le MÊME protocole JSON
// qu'utilise CoreBridge.swift (request/response + events sur stdin/stdout).

const { app, BrowserWindow, ipcMain, dialog, safeStorage, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { autoUpdater } = require('electron-updater');

// ── Config locale (équivalent AppConfig côté Mac) ─────────────────────
// Stockée en clair (sauf le PAT kDrive qui passe par safeStorage). Le
// fichier vit dans userData/config.json.
function configPath() { return path.join(app.getPath('userData'), 'config.json'); }
function readConfig() {
  try { return JSON.parse(fs.readFileSync(configPath(), 'utf8')); }
  catch { return {}; }
}
function writeConfig(obj) {
  try { fs.mkdirSync(path.dirname(configPath()), { recursive: true }); } catch {}
  fs.writeFileSync(configPath(), JSON.stringify(obj, null, 2));
}
function patPath() { return path.join(app.getPath('userData'), 'kdrive-pat.bin'); }
function readPAT() {
  try {
    if (!safeStorage.isEncryptionAvailable()) {
      // Fallback : lecture en clair (Linux sans keyring p.ex.).
      return fs.readFileSync(patPath() + '.plain', 'utf8');
    }
    const enc = fs.readFileSync(patPath());
    return safeStorage.decryptString(enc);
  } catch { return ''; }
}
function writePAT(pat) {
  try {
    if (!pat) {
      try { fs.unlinkSync(patPath()); } catch {}
      try { fs.unlinkSync(patPath() + '.plain'); } catch {}
      return;
    }
    if (safeStorage.isEncryptionAvailable()) {
      fs.writeFileSync(patPath(), safeStorage.encryptString(pat));
    } else {
      fs.writeFileSync(patPath() + '.plain', pat);
    }
  } catch (e) { console.warn('PAT write failed:', e); }
}

const isDev = process.argv.includes('--dev') || !app.isPackaged;

// Chemin du compagnon Node (core/) — en dev on lit le repo, en prod il vit
// dans extraResources/core.
const corePath = isDev
  ? path.join(__dirname, '..', 'core')
  : path.join(process.resourcesPath, 'core');

let mainWindow = null;
let coreProc = null;
const pending = new Map();      // requestId → { resolve, reject }
const eventListeners = new Set();

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100, height: 700, minWidth: 900, minHeight: 540,
    title: 'CrocShare',
    backgroundColor: '#1B1B1D',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false  // pour permettre le preload de require
    },
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default'
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  if (isDev) mainWindow.webContents.openDevTools({ mode: 'detach' });

  mainWindow.on('closed', () => { mainWindow = null; });
}

// ────────────────────────────────────────────────────────────────────────────
// Compagnon Node (core/index.js)
// ────────────────────────────────────────────────────────────────────────────

function startCore() {
  const indexPath = path.join(corePath, 'index.js');
  if (!fs.existsSync(indexPath)) {
    console.error(`Core not found at ${indexPath}`);
    dialog.showErrorBox('CrocShare', `P2P companion not found at ${indexPath}`);
    return;
  }

  // En prod sur Windows, on bundle son propre node.exe via electron-builder.
  // En dev, on utilise le node de l'env.
  const nodeBin = isDev ? 'node' : process.execPath;

  coreProc = spawn(nodeBin, [indexPath], {
    cwd: corePath,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: '1',  // permet de réutiliser le node d'Electron
      CROCSHARE_STORAGE: path.join(app.getPath('userData'), 'p2p-storage')
    },
    stdio: ['pipe', 'pipe', 'pipe']
  });

  coreProc.stdout.on('data', chunk => {
    // Protocole : 1 JSON par ligne.
    for (const line of chunk.toString().split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try { dispatchFromCore(JSON.parse(t)); }
      catch (e) { console.warn('core json parse:', t.slice(0, 80)); }
    }
  });
  coreProc.stderr.on('data', d => console.error('core stderr:', d.toString()));
  coreProc.on('exit', (code, signal) => {
    console.warn(`core exited code=${code} signal=${signal}`);
    coreProc = null;
    // Relance auto après 2 s (sauf si on quitte).
    if (mainWindow) setTimeout(startCore, 2000);
  });
}

function dispatchFromCore(msg) {
  if (msg.id != null && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(msg.error?.message || msg.error || 'RPC error'));
    else resolve(msg.result);
    return;
  }
  // Sinon, c'est un événement (peer.connected, peer.message, etc.).
  for (const fn of eventListeners) fn(msg);
}

let nextReqId = 1;
function coreRequest(method, params = {}) {
  return new Promise((resolve, reject) => {
    if (!coreProc) return reject(new Error('core not running'));
    const id = nextReqId++;
    pending.set(id, { resolve, reject });
    // Protocole : { id, method, params } — cf. core/rpc.js
    coreProc.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error('core request timeout'));
      }
    }, 30_000);
  });
}

// ────────────────────────────────────────────────────────────────────────────
// IPC entre renderer (React/HTML) et main
// ────────────────────────────────────────────────────────────────────────────

ipcMain.handle('p2p:request', async (_e, kind, params) => coreRequest(kind, params));

// Forward les events du core vers le renderer.
eventListeners.add(evt => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('p2p:event', evt);
  }
});

ipcMain.handle('app:openExternal', async (_e, url) => {
  const { shell } = require('electron');
  await shell.openExternal(url);
});

ipcMain.handle('app:storagePath', () => path.join(app.getPath('userData'), 'p2p-storage'));
ipcMain.handle('app:version', () => app.getVersion());
ipcMain.handle('app:platform', () => process.platform);
ipcMain.handle('app:home', () => app.getPath('home'));

// ── Config ─────────────────────────────────────────────────────────
ipcMain.handle('config:get', () => readConfig());
ipcMain.handle('config:set', (_e, obj) => {
  writeConfig({ ...readConfig(), ...obj });
  return readConfig();
});

// ── kDrive PAT (safeStorage) ───────────────────────────────────────
ipcMain.handle('pat:get', () => readPAT());
ipcMain.handle('pat:set', (_e, value) => { writePAT(value || ''); });
ipcMain.handle('pat:clear', () => { writePAT(''); });

// ── Dialog dossiers ────────────────────────────────────────────────
ipcMain.handle('dialog:pickFolder', async () => {
  const r = await dialog.showOpenDialog({
    properties: ['openDirectory', 'createDirectory'],
  });
  return r.canceled ? null : r.filePaths[0];
});
ipcMain.handle('dialog:pickFile', async (_e, options = {}) => {
  const r = await dialog.showOpenDialog({
    properties: ['openFile'],
    filters: options.filters || [],
  });
  return r.canceled ? null : r.filePaths[0];
});

// ── Relance de l'app (pour switch de langue) ───────────────────────
ipcMain.handle('app:relaunch', () => {
  app.relaunch();
  app.exit(0);
});

// ── Test kDrive (ping /2/drive/{id}) ───────────────────────────────
ipcMain.handle('kdrive:test', async (_e, { driveID }) => {
  const pat = readPAT();
  if (!pat) throw new Error('Aucun token enregistré.');
  if (!driveID) throw new Error('Drive ID manquant.');
  // Appel via fetch natif Node 18+.
  const url = `https://api.infomaniak.com/2/drive/${driveID}`;
  try {
    const resp = await fetch(url, { headers: { Authorization: `Bearer ${pat}` } });
    if (!resp.ok) {
      const t = await resp.text().catch(() => '');
      throw new Error(`HTTP ${resp.status}: ${t.slice(0, 160)}`);
    }
    return { ok: true };
  } catch (e) {
    throw new Error(e.message || 'Erreur réseau');
  }
});

// ────────────────────────────────────────────────────────────────────────────
// Cycle de vie
// ────────────────────────────────────────────────────────────────────────────

app.whenReady().then(() => {
  startCore();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });

  // Sparkle-equivalent côté Windows : electron-updater pointe sur le même
  // appcast GitHub (NSIS).
  if (!isDev) {
    autoUpdater.checkForUpdatesAndNotify().catch(e => console.warn('updater:', e));
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('will-quit', () => {
  if (coreProc) { coreProc.kill(); coreProc = null; }
});

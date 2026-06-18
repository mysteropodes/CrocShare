// CrocShare Windows — process principal Electron.
//
// Réutilise le compagnon Node.js existant (core/*.js du repo macOS) en le
// spawnant comme child_process. La communication suit le MÊME protocole JSON
// qu'utilise CoreBridge.swift (request/response + events sur stdin/stdout).

const { app, BrowserWindow, ipcMain, dialog, safeStorage, shell, utilityProcess } = require('electron');
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

function coreLogPath() { return path.join(app.getPath('userData'), 'core.log'); }
function appendCoreLog(line) {
  try {
    fs.mkdirSync(path.dirname(coreLogPath()), { recursive: true });
    fs.appendFileSync(coreLogPath(), `[${new Date().toISOString()}] ${line}\n`);
  } catch {}
}

let coreRestartCount = 0;

function startCore() {
  const indexPath = path.join(corePath, 'index.js');
  if (!fs.existsSync(indexPath)) {
    appendCoreLog(`ERROR core not found at ${indexPath}`);
    dialog.showErrorBox('CrocShare', `P2P companion not found at ${indexPath}`);
    return;
  }

  // Choix du binaire Node :
  //  - dev : `node` du PATH
  //  - prod : un vrai node.exe (Win) ou node (Mac) bundlé en extraResources.
  //    On évite ELECTRON_RUN_AS_NODE qui pose des problèmes d'ABI avec les
  //    modules natifs (sodium-native, udx-native).
  let nodeBin;
  if (isDev) {
    nodeBin = 'node';
  } else if (process.platform === 'win32') {
    nodeBin = path.join(process.resourcesPath, 'node-win', 'node.exe');
  } else if (process.platform === 'darwin') {
    nodeBin = path.join(process.resourcesPath, 'runtime', 'node');
  } else {
    nodeBin = 'node'; // Linux : on suppose node système.
  }
  if (process.platform !== 'win32' && !isDev) {
    // S'assurer qu'il est exécutable (extraResources préserve normalement,
    // mais belt+suspenders pour macOS).
    try { fs.chmodSync(nodeBin, 0o755); } catch {}
  }
  appendCoreLog(`Starting core: ${nodeBin} ${indexPath} (cwd: ${corePath}, isDev=${isDev}, exists=${fs.existsSync(nodeBin)})`);
  appendCoreLog(`process.execPath=${process.execPath}`);

  try {
    coreProc = spawn(nodeBin, [indexPath], {
      cwd: corePath,
      env: {
        ...process.env,
        CROCSHARE_STORAGE: path.join(app.getPath('userData'), 'p2p-storage'),
      },
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });
  } catch (e) {
    appendCoreLog(`ERROR spawn failed: ${e.stack || e.message}`);
    console.error('core spawn failed:', e);
    if (++coreRestartCount < 3) setTimeout(startCore, 3000);
    return;
  }

  appendCoreLog(`Core spawned pid=${coreProc.pid}`);

  coreProc.stdout.on('data', chunk => {
    const text = chunk.toString();
    appendCoreLog(`STDOUT: ${text.slice(0, 800)}`);
    for (const line of text.split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try { dispatchFromCore(JSON.parse(t)); }
      catch (e) { appendCoreLog(`json parse error: ${t.slice(0, 200)}`); }
    }
  });
  coreProc.stderr.on('data', d => {
    const text = d.toString();
    appendCoreLog(`STDERR: ${text}`);
    console.error('core stderr:', text);
  });
  coreProc.on('exit', (code, signal) => {
    appendCoreLog(`Core exited code=${code} signal=${signal}`);
    coreProc = null;
    if (mainWindow && ++coreRestartCount < 5) setTimeout(startCore, 2000);
  });
  coreProc.on('error', (e) => {
    appendCoreLog(`Core error: ${e.stack || e.message}`);
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

// Stats sur un fichier (taille en bytes), utilisé pour les attachments.
ipcMain.handle('file:stat', async (_e, filePath) => {
  try {
    const s = await fs.promises.stat(filePath);
    return { size: s.size, mtime: s.mtimeMs };
  } catch (e) { return { size: 0, error: e.message }; }
});

// File URL → for displaying received attachments in renderer.
ipcMain.handle('file:url', (_e, filePath) => {
  // Convertit en file:// — Chromium peut lire les fichiers locaux.
  return 'file://' + filePath.replace(/\\/g, '/');
});

// Lecture du log core pour diagnostic depuis l'UI.
ipcMain.handle('core:log', () => {
  try { return fs.readFileSync(coreLogPath(), 'utf8'); }
  catch (e) { return `(log inaccessible: ${e.message})`; }
});
ipcMain.handle('core:restart', () => {
  if (coreProc) { try { coreProc.kill(); } catch {} coreProc = null; }
  coreRestartCount = 0;
  startCore();
  return true;
});

// Sauvegarde un ArrayBuffer dans un fichier temporaire de l'app (utilisé
// pour les messages audio enregistrés via MediaRecorder).
ipcMain.handle('file:saveTempBuffer', async (_e, name, buffer) => {
  try {
    const tmpDir = path.join(app.getPath('userData'), 'tmp');
    fs.mkdirSync(tmpDir, { recursive: true });
    const target = path.join(tmpDir, name);
    fs.writeFileSync(target, Buffer.from(buffer));
    return target;
  } catch (e) {
    console.warn('saveTempBuffer failed:', e);
    return null;
  }
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

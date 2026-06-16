// CrocShare Windows — process principal Electron.
//
// Réutilise le compagnon Node.js existant (core/*.js du repo macOS) en le
// spawnant comme child_process. La communication suit le MÊME protocole JSON
// qu'utilise CoreBridge.swift (request/response + events sur stdin/stdout).

const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { autoUpdater } = require('electron-updater');

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
    if (msg.error) reject(new Error(msg.error));
    else resolve(msg.result);
    return;
  }
  // Sinon, c'est un événement (peer.connected, peer.message, etc.).
  for (const fn of eventListeners) fn(msg);
}

let nextReqId = 1;
function coreRequest(kind, params = {}) {
  return new Promise((resolve, reject) => {
    if (!coreProc) return reject(new Error('core not running'));
    const id = nextReqId++;
    pending.set(id, { resolve, reject });
    coreProc.stdin.write(JSON.stringify({ id, kind, params }) + '\n');
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

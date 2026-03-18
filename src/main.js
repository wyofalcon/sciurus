const { app, BrowserWindow, Tray, Menu, clipboard, nativeImage, globalShortcut, ipcMain, screen } = require('electron');
const path = require('path');
const Store = require('electron-store');
const ai = require('./ai');

const store = new Store({ name: 'quickclip-data' });
let tray = null;
let mainWindow = null;
let captureWindow = null;
let clipboardWatcher = null;
let lastClipHash = null;
let watcherPaused = false;
const DEFAULT_CATS = ['Uncategorized','cvstomize.com','PowerToys','LLM Setup','Hardware/GPU','Ideas','Code Patterns'];

// ── Clipboard image hash (detect new screenshots) ──
function getClipImageHash() {
  const img = clipboard.readImage();
  if (img.isEmpty()) return null;
  const s = img.getSize();
  const buf = img.toBitmap();
  return `${s.width}x${s.height}-${buf.slice(0, 32).toString('hex')}`;
}

// ── Main Window ──
function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 960, height: 700, show: false,
    title: 'QuickClip',
    backgroundColor: '#13131f',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  mainWindow.on('close', (e) => { e.preventDefault(); mainWindow.hide(); });
}

// ── Capture Popup ──
function createCaptureWindow(imageDataURL) {
  if (captureWindow && !captureWindow.isDestroyed()) {
    captureWindow.focus();
    captureWindow.webContents.send('new-screenshot', imageDataURL);
    return;
  }
  const { width: sw, height: sh } = screen.getPrimaryDisplay().workAreaSize;
  captureWindow = new BrowserWindow({
    width: 460, height: 520,
    x: sw - 480, y: 20,
    frame: false, alwaysOnTop: true,
    resizable: true, skipTaskbar: true,
    backgroundColor: '#1e1e2e',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  captureWindow.loadFile(path.join(__dirname, '..', 'renderer', 'capture.html'));
  captureWindow.once('ready-to-show', () => {
    captureWindow.show();
    if (imageDataURL) captureWindow.webContents.send('new-screenshot', imageDataURL);
  });
  captureWindow.on('closed', () => { captureWindow = null; });
}

// ── Clipboard Watcher ──
function startClipboardWatcher() {
  lastClipHash = getClipImageHash();
  clipboardWatcher = setInterval(() => {
    if (watcherPaused) return;
    const hash = getClipImageHash();
    if (hash && hash !== lastClipHash) {
      lastClipHash = hash;
      const img = clipboard.readImage();
      if (!img.isEmpty()) {
        createCaptureWindow(img.toDataURL());
      }
    }
  }, 500);
}

// ── System Tray ──
function createTray() {
  const icon = nativeImage.createEmpty();
  tray = new Tray(icon.isEmpty() ? nativeImage.createFromDataURL(
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAE1JREFU'
    + 'WGFoAAAADklEQVRIx2NgGAWjYBQMfQAABPAAATG1XiAAAAAASUVORK5CYII='
  ) : icon);
  const menu = Menu.buildFromTemplate([
    { label: 'Open QuickClip', click: () => { mainWindow.show(); mainWindow.focus(); } },
    { label: 'Quick Capture', click: () => createCaptureWindow(null) },
    { type: 'separator' },
    { label: 'Pause Watcher', type: 'checkbox', checked: false, click: (item) => {
      watcherPaused = item.checked;
    }},
    { type: 'separator' },
    { label: 'Quit', click: () => app.exit() },
  ]);
  tray.setToolTip('QuickClip ⚡');
  tray.setContextMenu(menu);
  tray.on('click', () => { mainWindow.show(); mainWindow.focus(); });
}

// ── IPC Handlers ──
ipcMain.handle('get-clips', () => store.get('clips', []));
ipcMain.handle('get-categories', () => store.get('categories', [
  'Uncategorized','cvstomize.com','PowerToys','LLM Setup','Hardware/GPU','Ideas','Code Patterns'
]));
ipcMain.handle('save-clip', (_, clip) => {
  const clips = store.get('clips', []);
  clips.unshift(clip);
  store.set('clips', clips);
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('clips-updated', clips);
  return true;
});
ipcMain.handle('update-clip', (_, id, updates) => {
  const clips = store.get('clips', []);
  const idx = clips.findIndex(c => c.id === id);
  if (idx !== -1) { clips[idx] = { ...clips[idx], ...updates }; store.set('clips', clips); }
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('clips-updated', clips);
  return true;
});
ipcMain.handle('delete-clip', (_, id) => {
  const clips = store.get('clips', []).filter(c => c.id !== id);
  store.set('clips', clips);
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('clips-updated', clips);
  return true;
});
ipcMain.handle('save-categories', (_, cats) => { store.set('categories', cats); return true; });
ipcMain.handle('ai-categorize', async (_, comment) => {
  const cats = store.get('categories', DEFAULT_CATS);
  return ai.categorize(comment, cats);
});
ipcMain.handle('ai-search', async (_, query) => {
  const clips = store.get('clips', []);
  return ai.search(query, clips);
});
ipcMain.handle('has-api-key', () => !!ai.getApiKey());

ipcMain.on('close-capture', () => {
  if (captureWindow && !captureWindow.isDestroyed()) captureWindow.close();
});
ipcMain.on('open-capture', () => {
  const img = clipboard.readImage();
  createCaptureWindow(img.isEmpty() ? null : img.toDataURL());
});

// ── App Lifecycle ──
app.whenReady().then(() => {
  createMainWindow();
  createTray();
  startClipboardWatcher();
  globalShortcut.register('CommandOrControl+Shift+Q', () => {
    const img = clipboard.readImage();
    createCaptureWindow(img.isEmpty() ? null : img.toDataURL());
  });
});
app.on('window-all-closed', (e) => e.preventDefault());
app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  if (clipboardWatcher) clearInterval(clipboardWatcher);
});

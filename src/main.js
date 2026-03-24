// src/main.js — Electron main process: tray, hotkey, IPC, clipboard watcher, PostgreSQL

// Clear before requiring electron — inherited from VS Code / Claude Code shell
delete process.env.ELECTRON_RUN_AS_NODE;

const { app, BrowserWindow, Tray, Menu, clipboard, nativeImage, globalShortcut, ipcMain, screen, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const db = require('./db');
const ai = require('./ai');

// ── .env loader (manual — dotenv v17 changed its API) ──

const ENV_PATH = path.join(__dirname, '..', '.env');
if (fs.existsSync(ENV_PATH)) {
  for (const line of fs.readFileSync(ENV_PATH, 'utf8').split('\n')) {
    const match = line.match(/^([^#=]+)=(.*)$/);
    if (match && !process.env[match[1].trim()]) {
      process.env[match[1].trim()] = match[2].trim();
    }
  }
}

// ── Constants ──

const CLIPBOARD_POLL_MS = 500;
const DEFAULT_CATEGORIES = [
  'Uncategorized', 'cvstomize.com', 'PowerToys', 'LLM Setup',
  'Hardware/GPU', 'Ideas', 'Code Patterns',
];
const ALLOWED_CLIP_FIELDS = [
  'category', 'tags', 'aiSummary', 'url', 'status', 'comments', 'project_id', 'comment',
];

// Tiny 32x32 fallback icon (transparent PNG) for the system tray
const FALLBACK_TRAY_ICON = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0'
  + 'AAAAAXNSR0IArs4c6QAAAE1JREFUWGFoAAAADklEQVRIx2NgGAWjYBQMfQAABPAAATG1XiAAAAAASUVORK5CYII=';

// ── State ──

let tray = null;
let mainWindow = null;
let captureWindow = null;
let clipboardWatcher = null;
let lastClipHash = null;
let watcherPaused = false;
let isQuitting = false;

// ── Helpers ──

/** Send an event to the main window if it exists. */
function notifyMainWindow(channel, data) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, data);
  }
}

/** Read the clipboard image and return a data URL, or null if empty. */
function getClipboardImageURL() {
  const img = clipboard.readImage();
  return img.isEmpty() ? null : img.toDataURL();
}

/** Hash the current clipboard image to detect changes. */
function getClipboardImageHash() {
  const img = clipboard.readImage();
  if (img.isEmpty()) return null;
  const size = img.getSize();
  const buf = img.toBitmap();
  return `${size.width}x${size.height}-${buf.slice(0, 32).toString('hex')}`;
}

/** Sanitize an update object to only include allowed clip fields. */
function sanitizeUpdates(updates) {
  const clean = {};
  for (const key of ALLOWED_CLIP_FIELDS) {
    if (key in updates) clean[key] = updates[key];
  }
  return clean;
}

// ── Windows ──

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1100, height: 750, show: false,
    title: 'Sciurus',
    backgroundColor: '#13131f',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  mainWindow.on('close', (e) => {
    if (!isQuitting) {
      e.preventDefault();
      mainWindow.hide();
    }
  });
}

function createCaptureWindow(imageDataURL) {
  if (captureWindow && !captureWindow.isDestroyed()) {
    captureWindow.focus();
    captureWindow.webContents.send('new-screenshot', imageDataURL);
    return;
  }
  const { width: screenW } = screen.getPrimaryDisplay().workAreaSize;
  captureWindow = new BrowserWindow({
    width: 460, height: 580,
    x: screenW - 480, y: 20,
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
  lastClipHash = getClipboardImageHash();
  clipboardWatcher = setInterval(() => {
    if (watcherPaused) return;
    const hash = getClipboardImageHash();
    if (hash && hash !== lastClipHash) {
      lastClipHash = hash;
      const url = getClipboardImageURL();
      if (url) createCaptureWindow(url);
    }
  }, CLIPBOARD_POLL_MS);
}

// ── System Tray ──

function createTray() {
  const icon = nativeImage.createFromDataURL(FALLBACK_TRAY_ICON);
  tray = new Tray(icon);
  tray.setToolTip('Sciurus');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open Sciurus', click: () => { mainWindow.show(); mainWindow.focus(); } },
    { label: 'Quick Capture', click: () => createCaptureWindow(null) },
    { type: 'separator' },
    { label: 'Pause Watcher', type: 'checkbox', checked: false, click: (item) => {
      watcherPaused = item.checked;
    }},
    { type: 'separator' },
    { label: 'Quit', click: () => { isQuitting = true; app.quit(); } },
  ]));
  tray.on('click', () => { mainWindow.show(); mainWindow.focus(); });
}

// ── Migration from electron-store ──

async function migrateIfNeeded() {
  try {
    const Store = require('electron-store');
    const oldStore = new Store({ name: 'sciurus-data' });
    const oldClips = oldStore.get('clips', []);
    if (oldClips.length === 0) return;

    // Check if DB already has clips (already migrated)
    const existing = await db.getClips();
    if (existing.length > 0) return;

    console.log(`[Sciurus] Migrating ${oldClips.length} clips from electron-store...`);
    const oldCategories = oldStore.get('categories', DEFAULT_CATEGORIES);
    const ok = await db.migrateFromStore({ clips: oldClips, categories: oldCategories });
    if (ok) console.log('[Sciurus] Migration complete.');
  } catch (e) {
    console.log('[Sciurus] No electron-store data to migrate (or already migrated).');
  }
}

// ── Auto-Categorize ──

/** Retry AI categorization for any uncategorized clips from previous sessions. */
async function retryUncategorized() {
  if (!ai.isEnabled()) return;
  const clips = await db.getClips();
  const pending = clips.filter((c) => c.category === 'Uncategorized' && c.comment);
  if (!pending.length) return;
  console.log(`[Sciurus] Retrying AI for ${pending.length} uncategorized clip(s)...`);
  for (const clip of pending) {
    await autoCategorize(clip.id, clip.comment, clip.image);
  }
}

/** Run AI categorization in the background after a clip is saved. */
async function autoCategorize(clipId, comment, imageData) {
  try {
    const cats = await db.getCategories();
    const result = await ai.categorize(comment, cats, imageData);
    if (!result) return;

    const updates = {};
    if (result.category) updates.category = result.category;
    if (result.tags) updates.tags = result.tags;
    if (result.summary) updates.aiSummary = result.summary;
    if (result.url) updates.url = result.url;

    if (Object.keys(updates).length) {
      await db.updateClip(clipId, updates);

      // Add new category if needed
      if (result.category) {
        await db.saveCategory(result.category);
      }

      notifyMainWindow('clips-changed');
    }
    console.log(`[Sciurus] AI categorized: "${comment.slice(0, 30)}" → ${result.category}`);
  } catch (e) {
    console.error('[Sciurus] Auto-categorize failed:', e.message);
  }
}

// ── IPC Handlers: Clips ──

ipcMain.handle('get-clips', () => db.getClips());
ipcMain.handle('get-general-clips', () => db.getClips(null));
ipcMain.handle('get-clips-for-project', (_, projectId) => db.getClips(projectId));

ipcMain.handle('save-clip', async (_, clip) => {
  if (!clip || typeof clip.id !== 'string') return false;
  await db.saveClip(clip);
  notifyMainWindow('clips-changed');

  // Auto-categorize in the background
  if (clip.category === 'Uncategorized' && clip.comment && ai.isEnabled()) {
    console.log(`[Sciurus] Starting AI categorization for: "${clip.comment.slice(0, 30)}"`);
    autoCategorize(clip.id, clip.comment, clip.image);
  }
  return true;
});

ipcMain.handle('update-clip', async (_, id, updates) => {
  if (typeof id !== 'string' || !updates) return false;
  const safe = sanitizeUpdates(updates);
  await db.updateClip(id, safe);
  notifyMainWindow('clips-changed');
  return true;
});

ipcMain.handle('delete-clip', async (_, id) => {
  if (typeof id !== 'string') return false;
  await db.deleteClip(id);
  notifyMainWindow('clips-changed');
  return true;
});

ipcMain.handle('assign-clip-to-project', async (_, clipId, projectId) => {
  await db.updateClip(clipId, { project_id: projectId });
  notifyMainWindow('clips-changed');
  return true;
});

// ── IPC Handlers: Categories ──

ipcMain.handle('get-categories', () => db.getCategories());

ipcMain.handle('save-categories', async (_, cats) => {
  if (!Array.isArray(cats)) return false;
  for (const name of cats) await db.saveCategory(name);
  return true;
});

// ── IPC Handlers: Projects ──

ipcMain.handle('get-projects', () => db.getProjects());
ipcMain.handle('get-project', (_, id) => db.getProject(id));

ipcMain.handle('create-project', async (_, data) => {
  const project = await db.createProject(data);
  notifyMainWindow('projects-changed');
  return project;
});

ipcMain.handle('update-project', async (_, id, data) => {
  const project = await db.updateProject(id, data);
  notifyMainWindow('projects-changed');
  return project;
});

ipcMain.handle('delete-project', async (_, id) => {
  await db.deleteProject(id);
  notifyMainWindow('projects-changed');
  notifyMainWindow('clips-changed');
  return true;
});

// ── IPC Handlers: Settings ──

ipcMain.handle('get-settings', () => db.getAllSettings());
ipcMain.handle('get-setting', (_, key) => db.getSettings(key));
ipcMain.handle('save-setting', async (_, key, value) => {
  await db.saveSetting(key, value);
  return true;
});

// ── IPC Handlers: AI ──

ipcMain.handle('ai-categorize', async (_, comment, imageData) => {
  const cats = await db.getCategories();
  return ai.categorize(comment, cats, imageData);
});

ipcMain.handle('ai-search', async (_, query) => {
  const clips = await db.getClips();
  return ai.search(query, clips);
});

ipcMain.handle('has-api-key', () => ai.isEnabled());

// ── IPC Handlers: Window Controls ──

ipcMain.on('close-capture', () => {
  if (captureWindow && !captureWindow.isDestroyed()) captureWindow.close();
});

ipcMain.on('hide-main', () => {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.hide();
});

ipcMain.on('open-capture', () => {
  createCaptureWindow(getClipboardImageURL());
});

// ── Auto-launch on login ──

if (app.isPackaged) {
  app.setLoginItemSettings({ openAtLogin: true, name: 'Sciurus' });
}

// ── App Lifecycle ──

app.whenReady().then(async () => {
  createMainWindow();
  createTray();

  // Initialize database (waits for Docker PostgreSQL)
  const dbReady = await db.init();
  if (!dbReady) {
    dialog.showErrorBox(
      'Sciurus — Database Error',
      'Could not connect to PostgreSQL.\n\nMake sure Docker is running:\n  docker-compose up -d\n\nThen restart Sciurus.'
    );
    isQuitting = true;
    app.quit();
    return;
  }

  // One-time migration from electron-store
  await migrateIfNeeded();

  // Show the main window on launch
  mainWindow.show();
  mainWindow.focus();

  startClipboardWatcher();
  ai.init();
  retryUncategorized();

  const hotkey = process.env.HOTKEY_COMBO || 'CommandOrControl+Shift+Q';
  globalShortcut.register(hotkey, () => {
    createCaptureWindow(getClipboardImageURL());
  });
});

app.on('before-quit', () => { isQuitting = true; });
app.on('window-all-closed', (e) => e.preventDefault());

app.on('will-quit', async () => {
  globalShortcut.unregisterAll();
  if (clipboardWatcher) clearInterval(clipboardWatcher);
  await db.close();
});

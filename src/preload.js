const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('quickclip', {
  // Capture window
  onScreenshot: (cb) => ipcRenderer.on('new-screenshot', (_, data) => cb(data)),
  closeCapture: () => ipcRenderer.send('close-capture'),
  openCapture: () => ipcRenderer.send('open-capture'),

  // Data
  getClips: () => ipcRenderer.invoke('get-clips'),
  getCategories: () => ipcRenderer.invoke('get-categories'),
  saveClip: (clip) => ipcRenderer.invoke('save-clip', clip),
  updateClip: (id, updates) => ipcRenderer.invoke('update-clip', id, updates),
  deleteClip: (id) => ipcRenderer.invoke('delete-clip', id),
  saveCategories: (cats) => ipcRenderer.invoke('save-categories', cats),

  // AI
  aiCategorize: (comment, imageData) => ipcRenderer.invoke('ai-categorize', comment, imageData),
  aiSearch: (query) => ipcRenderer.invoke('ai-search', query),
  hasApiKey: () => ipcRenderer.invoke('has-api-key'),

  // Listen for updates from main process
  onClipsUpdated: (cb) => ipcRenderer.on('clips-updated', (_, clips) => cb(clips)),
});

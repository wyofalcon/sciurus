// renderer/toolbar.js — Floating annotation toolbar logic

const toolbar = document.getElementById('toolbar');
const pill = document.getElementById('pill');
const projectNameEl = document.getElementById('projectName');

let isMinimized = false;

// ── Project Name ──

async function loadProjectName() {
  const name = await window.quickclip.getToolbarProject();
  if (name) {
    projectNameEl.textContent = name;
    projectNameEl.classList.add('active');
  } else {
    projectNameEl.textContent = 'No project';
    projectNameEl.classList.remove('active');
  }
}

// ── Draw Mode ──

function enterDraw(color) {
  window.quickclip.enterDrawMode(color);
}

// ── Actions ──

function openSciurus() {
  window.quickclip.showMain();
}

function captureSnippet() {
  window.quickclip.takeSnippet();
}

// ── Minimize / Restore ──

function minimizeToolbar() {
  toolbar.classList.add('hidden');
  pill.classList.remove('hidden');
  isMinimized = true;
  window.quickclip.minimizeToolbar();
}

function restoreToolbar() {
  pill.classList.add('hidden');
  toolbar.classList.remove('hidden');
  isMinimized = false;
  window.quickclip.restoreToolbar();
}

function closeToolbar() {
  window.quickclip.closeToolbar();
}

// ── Init ──

loadProjectName();

// Refresh project name when main window notifies of changes
window.quickclip.onProjectsChanged(() => loadProjectName());

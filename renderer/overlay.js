// renderer/overlay.js — Fullscreen transparent overlay for annotation + region capture

const COLORS = {
  red: '#ff0000',
  green: '#00ff00',
  pink: '#ff69b4',
};

// ── State ──

let activeColor = 'red';
let isDrawing = false;
let isRegionMode = false;
let regionStart = null;
let regionRect = null;
let screenshotDataUrl = null; // Set when entering region-select mode

// ── Drawing Canvas ──

const drawCanvas = document.getElementById('drawCanvas');
const drawCtx = drawCanvas.getContext('2d');

function resizeDrawCanvas() {
  drawCanvas.width = window.innerWidth;
  drawCanvas.height = window.innerHeight;
}
resizeDrawCanvas();
window.addEventListener('resize', resizeDrawCanvas);

function setPenStyle() {
  drawCtx.strokeStyle = COLORS[activeColor] || COLORS.red;
  drawCtx.lineWidth = 3;
  drawCtx.lineCap = 'round';
  drawCtx.lineJoin = 'round';
}

// ── Mouse Drawing ──

drawCanvas.addEventListener('mousedown', (e) => {
  if (isRegionMode) return;
  if (e.button === 2) {
    // Right-click exits draw mode
    window.quickclip.exitDrawMode();
    return;
  }
  isDrawing = true;
  setPenStyle();
  drawCtx.beginPath();
  drawCtx.moveTo(e.clientX, e.clientY);
});

drawCanvas.addEventListener('mousemove', (e) => {
  if (!isDrawing || isRegionMode) return;
  drawCtx.lineTo(e.clientX, e.clientY);
  drawCtx.stroke();
});

drawCanvas.addEventListener('mouseup', () => {
  isDrawing = false;
});

// Prevent context menu on right-click
drawCanvas.addEventListener('contextmenu', (e) => e.preventDefault());

// ── Keyboard Shortcuts ──

document.addEventListener('keydown', (e) => {
  if (isRegionMode) {
    if (e.key === 'Escape') {
      exitRegionMode();
    }
    return;
  }
  if (e.key === 'Escape') {
    window.quickclip.exitDrawMode();
  } else if (e.key === '1') {
    activeColor = 'red';
  } else if (e.key === '2') {
    activeColor = 'green';
  } else if (e.key === '3') {
    activeColor = 'pink';
  } else if (e.key === 's' || e.key === 'S') {
    window.quickclip.takeSnippet();
  }
});

// ── IPC: Color change from toolbar ──

window.quickclip.onColorChange((color) => {
  if (COLORS[color]) activeColor = color;
});

// ── Region Select Mode ──

const regionUI = document.getElementById('regionUI');
const regionCanvas = document.getElementById('regionCanvas');
const regionCtx = regionCanvas.getContext('2d');

window.quickclip.onEnterRegionSelect((dataUrl) => {
  screenshotDataUrl = dataUrl;
  enterRegionMode();
});

function enterRegionMode() {
  isRegionMode = true;
  regionCanvas.width = window.innerWidth;
  regionCanvas.height = window.innerHeight;

  // Draw the screenshot + annotations composited as the background
  const img = new Image();
  img.onload = () => {
    // Draw screenshot
    regionCtx.drawImage(img, 0, 0, regionCanvas.width, regionCanvas.height);
    // Draw annotations on top
    regionCtx.drawImage(drawCanvas, 0, 0);
    // Apply dark scrim
    regionCtx.fillStyle = 'rgba(0, 0, 0, 0.4)';
    regionCtx.fillRect(0, 0, regionCanvas.width, regionCanvas.height);

    // Hide the draw canvas, show region UI
    drawCanvas.style.display = 'none';
    regionUI.classList.remove('hidden');
  };
  img.src = screenshotDataUrl;
}

function exitRegionMode() {
  isRegionMode = false;
  regionUI.classList.add('hidden');
  drawCanvas.style.display = 'block';
  regionStart = null;
  regionRect = null;
  // If there were no annotations, just close
  if (isCanvasEmpty()) {
    window.quickclip.exitDrawMode();
  }
}

function isCanvasEmpty() {
  const pixels = drawCtx.getImageData(0, 0, drawCanvas.width, drawCanvas.height).data;
  for (let i = 3; i < pixels.length; i += 4) {
    if (pixels[i] > 0) return false;
  }
  return true;
}

// ── Region Drag ──

regionCanvas.addEventListener('mousedown', (e) => {
  regionStart = { x: e.clientX, y: e.clientY };
  regionRect = null;
});

regionCanvas.addEventListener('mousemove', (e) => {
  if (!regionStart) return;
  regionRect = {
    x: Math.min(regionStart.x, e.clientX),
    y: Math.min(regionStart.y, e.clientY),
    w: Math.abs(e.clientX - regionStart.x),
    h: Math.abs(e.clientY - regionStart.y),
  };
  redrawRegion();
});

regionCanvas.addEventListener('mouseup', () => {
  if (regionRect && regionRect.w > 10 && regionRect.h > 10) {
    cropAndSend();
  }
  regionStart = null;
});

function redrawRegion() {
  // Redraw the composited image with scrim
  const img = new Image();
  img.onload = () => {
    regionCtx.clearRect(0, 0, regionCanvas.width, regionCanvas.height);
    regionCtx.drawImage(img, 0, 0, regionCanvas.width, regionCanvas.height);
    regionCtx.drawImage(drawCanvas, 0, 0);
    regionCtx.fillStyle = 'rgba(0, 0, 0, 0.4)';
    regionCtx.fillRect(0, 0, regionCanvas.width, regionCanvas.height);

    if (regionRect) {
      // Clear the scrim inside the selected rectangle to show the bright region
      regionCtx.clearRect(regionRect.x, regionRect.y, regionRect.w, regionRect.h);
      regionCtx.drawImage(img, regionRect.x, regionRect.y, regionRect.w, regionRect.h,
        regionRect.x, regionRect.y, regionRect.w, regionRect.h);
      // Draw annotations inside region
      regionCtx.drawImage(drawCanvas, regionRect.x, regionRect.y, regionRect.w, regionRect.h,
        regionRect.x, regionRect.y, regionRect.w, regionRect.h);
      // Selection border
      regionCtx.strokeStyle = '#fff';
      regionCtx.lineWidth = 2;
      regionCtx.setLineDash([6, 3]);
      regionCtx.strokeRect(regionRect.x, regionRect.y, regionRect.w, regionRect.h);
      regionCtx.setLineDash([]);
    }
  };
  img.src = screenshotDataUrl;
}

function cropAndSend() {
  // Create a crop canvas with the selected region
  const cropCanvas = document.createElement('canvas');
  cropCanvas.width = regionRect.w;
  cropCanvas.height = regionRect.h;
  const cropCtx = cropCanvas.getContext('2d');

  // Draw screenshot region
  const img = new Image();
  img.onload = () => {
    cropCtx.drawImage(img, regionRect.x, regionRect.y, regionRect.w, regionRect.h,
      0, 0, regionRect.w, regionRect.h);
    // Draw annotation region on top
    cropCtx.drawImage(drawCanvas, regionRect.x, regionRect.y, regionRect.w, regionRect.h,
      0, 0, regionRect.w, regionRect.h);
    // Send as data URL
    const dataUrl = cropCanvas.toDataURL('image/png');
    window.quickclip.snippetCaptured(dataUrl);
  };
  img.src = screenshotDataUrl;
}

// renderer/capture.js — Capture popup: screenshot preview, note input, save

// ── State ──

let screenshotData = null;
let selectedCat = '';
let categories = [];

// ── Screenshot listener ──

window.quickclip.onScreenshot((dataURL) => {
  screenshotData = dataURL;
  document.getElementById('ssImg').src = dataURL;
  document.getElementById('ssImg').classList.remove('hidden');
  document.getElementById('emptyImg').classList.add('hidden');
  updateSaveBtn();
  document.getElementById('commentInput').focus();
});

// ── Init: load categories ──

(async () => {
  categories = await window.quickclip.getCategories();
  renderCategories();
  // Focus the comment input immediately so user can start typing
  document.getElementById('commentInput').focus();
})();

// ── Category Picker ──

function renderCategories() {
  const wrap = document.getElementById('catWrap');
  wrap.innerHTML = '';
  categories.filter((c) => c !== 'Uncategorized').forEach((cat) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = cat;
    btn.className = 'cat-btn' + (selectedCat === cat ? ' active' : '');
    btn.onclick = () => {
      selectedCat = selectedCat === cat ? '' : cat;
      renderCategories();
    };
    wrap.appendChild(btn);
  });
}

// ── Save Button State ──

function updateSaveBtn() {
  const comment = document.getElementById('commentInput').value.trim();
  const btn = document.getElementById('saveBtn');
  const canSave = comment || screenshotData;
  btn.disabled = !canSave;
}

document.getElementById('commentInput').addEventListener('input', updateSaveBtn);

// ── Actions ──

async function save() {
  const comment = document.getElementById('commentInput').value.trim();
  if (!comment && !screenshotData) return;

  // Disable button to prevent double-click
  const btn = document.getElementById('saveBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  try {
    const clip = {
      id: Date.now().toString(),
      image: screenshotData,
      comment,
      category: selectedCat || 'Uncategorized',
      tags: [],
      aiSummary: null,
      status: 'parked',
      timestamp: Date.now(),
      comments: [],
    };
    await window.quickclip.saveClip(clip);
    window.quickclip.closeCapture();
  } catch (e) {
    console.error('[Capture] Save failed:', e);
    btn.textContent = 'Error — try again';
    btn.disabled = false;
  }
}

function closeWin() {
  window.quickclip.closeCapture();
}

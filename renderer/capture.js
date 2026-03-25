// renderer/capture.js — Capture popup: screenshot preview, note input, save

// ── State ──

let screenshotData = null;
let windowMeta = null;
let selectedCat = '';
let selectedProject = null;
let categories = [];
let projects = [];

// ── Screenshot listener ──

window.quickclip.onScreenshot((dataURL, meta) => {
  screenshotData = dataURL;
  windowMeta = meta || null;
  document.getElementById('ssImg').src = dataURL;
  document.getElementById('ssImg').classList.remove('hidden');
  document.getElementById('emptyImg').classList.add('hidden');
  updateSaveBtn();
  document.getElementById('commentInput').focus();
});

// ── Init: load categories + projects ──

(async () => {
  [categories, projects] = await Promise.all([
    window.quickclip.getCategories(),
    window.quickclip.getProjects(),
  ]);
  renderCategories();
  renderProjects();
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

// ── Project Picker ──

function renderProjects() {
  const wrap = document.getElementById('projectWrap');
  wrap.innerHTML = '';
  if (projects.length === 0) {
    wrap.innerHTML = '<span class="field-hint" style="font-size:11px;color:#555">No projects yet</span>';
    return;
  }
  projects.forEach((proj) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = proj.name;
    btn.className = 'cat-btn proj-btn' + (selectedProject === proj.id ? ' active' : '');
    if (selectedProject === proj.id) {
      btn.style.borderColor = proj.color;
      btn.style.color = proj.color;
      btn.style.background = proj.color + '22';
    }
    btn.onclick = () => {
      selectedProject = selectedProject === proj.id ? null : proj.id;
      renderProjects();
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

  const btn = document.getElementById('saveBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';

  try {
    const clip = {
      id: Date.now().toString(),
      image: screenshotData,
      comment,
      category: selectedCat || 'Uncategorized',
      project_id: selectedProject || null,
      tags: [],
      aiSummary: null,
      status: 'parked',
      timestamp: Date.now(),
      comments: [],
      window_title: windowMeta?.title || null,
      process_name: windowMeta?.processName || null,
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

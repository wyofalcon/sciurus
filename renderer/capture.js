let screenshotData = null;
let selectedCat = '';
let categories = [];

// Listen for screenshot from main process
window.quickclip.onScreenshot((dataURL) => {
  screenshotData = dataURL;
  document.getElementById('ssImg').src = dataURL;
  document.getElementById('ssImg').style.display = 'block';
  document.getElementById('emptyImg').style.display = 'none';
  updateSaveBtn();
  document.getElementById('commentInput').focus();
});

// Load categories
(async () => {
  categories = await window.quickclip.getCategories();
  renderCats();
})();

function renderCats() {
  const wrap = document.getElementById('catWrap');
  wrap.innerHTML = '';
  categories.filter(c => c !== 'Uncategorized').forEach(cat => {
    const btn = document.createElement('button');
    btn.textContent = cat;
    btn.className = selectedCat === cat ? 'active' : '';
    btn.style.cssText = `padding:3px 10px;border-radius:6px;font-size:11px;cursor:pointer;
      border:1px solid ${selectedCat===cat?'#3b82f6':'#333'};
      background:${selectedCat===cat?'#3b82f622':'transparent'};
      color:${selectedCat===cat?'#3b82f6':'#777'}`;
    btn.onclick = () => { selectedCat = selectedCat===cat?'':cat; renderCats(); };
    wrap.appendChild(btn);
  });
}

function updateSaveBtn() {
  const comment = document.getElementById('commentInput').value.trim();
  const btn = document.getElementById('saveBtn');
  const ok = comment || screenshotData;
  btn.disabled = !ok;
  btn.style.opacity = ok ? '1' : '0.35';
}

document.getElementById('commentInput').addEventListener('input', updateSaveBtn);

async function save() {
  const comment = document.getElementById('commentInput').value.trim();
  if (!comment && !screenshotData) return;
  const clip = {
    id: Date.now().toString(),
    image: screenshotData,
    comment: comment,
    category: selectedCat || 'Uncategorized',
    tags: [],
    aiSummary: null,
    status: 'parked',
    timestamp: Date.now(),
    comments: [],
  };
  await window.quickclip.saveClip(clip);
  window.quickclip.closeCapture();
}

function closeWin() {
  window.quickclip.closeCapture();
}

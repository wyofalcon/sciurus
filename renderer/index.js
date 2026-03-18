let clips = [];
let categories = [];
let filterCat = 'All';
let filterStatus = 'all';
let aiMatchedIds = null;
let searchQuery = '';

// ── Init ──
(async () => {
  clips = await window.quickclip.getClips();
  categories = await window.quickclip.getCategories();
  const hasKey = await window.quickclip.hasApiKey();
  if (!hasKey) document.getElementById('noKeyBanner').style.display = 'block';
  renderAll();
})();

// Listen for live updates from capture window
window.quickclip.onClipsUpdated((updated) => {
  clips = updated;
  renderAll();
  // Auto-categorize newest clip if it has a comment and is uncategorized
  const newest = clips[0];
  if (newest && newest.category === 'Uncategorized' && newest.comment) {
    aiCategorize(newest);
  }
});

// ── AI Functions ──
async function aiCategorize(clip) {
  document.getElementById('aiBar').style.display = 'flex';
  document.getElementById('aiBarMsg').textContent = 'AI categorizing...';
  try {
    const result = await window.quickclip.aiCategorize(clip.comment);
    if (result) {
      const updates = {};
      if (result.category && clip.category === 'Uncategorized') updates.category = result.category;
      if (result.tags) updates.tags = result.tags;
      if (result.summary) updates.aiSummary = result.summary;
      if (Object.keys(updates).length) {
        await window.quickclip.updateClip(clip.id, updates);
        Object.assign(clip, updates);
        if (result.category && !categories.includes(result.category)) {
          categories.push(result.category);
          await window.quickclip.saveCategories(categories);
        }
        renderAll();
      }
    }
  } catch (e) { console.error('AI categorize failed:', e); }
  document.getElementById('aiBar').style.display = 'none';
}

async function doAiSearch() {
  searchQuery = document.getElementById('searchInput').value.trim();
  if (!searchQuery) { clearSearch(); return; }
  const btn = document.getElementById('aiSearchBtn');
  btn.disabled = true; btn.textContent = '...';
  try {
    aiMatchedIds = await window.quickclip.aiSearch(searchQuery);
  } catch (e) { console.error('AI search failed:', e); }
  btn.disabled = false; btn.textContent = '\u2728 AI Search';
  renderClips();
}

function clearSearch() {
  aiMatchedIds = null; searchQuery = '';
  document.getElementById('searchInput').value = '';
  document.getElementById('aiResultBar').style.display = 'none';
  renderClips();
}

function openCapture() {
  window.quickclip.openCapture();
}

// ── Filter handlers ──
function setCat(cat) {
  filterCat = cat; aiMatchedIds = null;
  renderAll();
}
function setStatus(s) {
  filterStatus = s;
  document.querySelectorAll('[data-status]').forEach(b => {
    b.classList.toggle('active', b.dataset.status === s);
  });
  renderClips();
}

// ── Render ──
function renderAll() {
  renderSidebar();
  renderClips();
  const parked = clips.filter(c => c.status === 'parked').length;
  document.getElementById('subtitle').textContent =
    `Screenshot \u2192 Comment \u2192 Done. AI handles the rest. \u2014 ${clips.length} clips` +
    (parked > 0 ? ` \u00b7 ${parked} parked` : '');
}

function renderSidebar() {
  const list = document.getElementById('catList');
  const allCats = ['All', ...categories.filter(c => c !== 'Uncategorized')];
  list.innerHTML = allCats.map(c => {
    const n = c === 'All' ? clips.length : clips.filter(x => x.category === c).length;
    if (c !== 'All' && n === 0) return '';
    return `<button class="sb-btn ${filterCat===c?'active':''}" onclick="setCat('${c.replace(/'/g,"\\'")}')">`
      + `<span>${c}</span><span style="font-size:10px;color:#555">${n}</span></button>`;
  }).join('');
}

function getFiltered() {
  let f = clips;
  if (filterCat !== 'All') f = f.filter(c => c.category === filterCat);
  if (filterStatus !== 'all') f = f.filter(c => c.status === filterStatus);
  if (aiMatchedIds) f = f.filter(c => aiMatchedIds.includes(c.id));
  else if (searchQuery) {
    const q = searchQuery.toLowerCase();
    f = f.filter(c =>
      (c.comment||'').toLowerCase().includes(q) ||
      (c.category||'').toLowerCase().includes(q) ||
      (c.tags||[]).some(t => t.includes(q)) ||
      (c.aiSummary||'').toLowerCase().includes(q) ||
      (c.comments||[]).some(x => x.text.toLowerCase().includes(q))
    );
  }
  return f;
}

function renderClips() {
  const filtered = getFiltered();
  const bar = document.getElementById('aiResultBar');
  if (aiMatchedIds) {
    bar.style.display = 'flex';
    document.getElementById('aiResultText').textContent =
      `\u2728 ${filtered.length} result${filtered.length!==1?'s':''}`;
  } else { bar.style.display = 'none'; }
  const el = document.getElementById('clipList');
  if (filtered.length === 0) {
    el.innerHTML = `<div class="empty"><div class="ico">\u26a1</div>`
      + `<div style="font-size:14px">${clips.length===0?'No clips yet':'No matches'}</div>`
      + `<div style="font-size:12px;color:#444;margin-top:4px">`
      + `${clips.length===0?'Take a screenshot \u2014 capture pops automatically':'Try a different search'}</div></div>`;
    return;
  }
  el.innerHTML = filtered.map(c => renderClipCard(c)).join('');
}

function timeAgo(ts) {
  const d = Date.now() - ts, m = Math.floor(d/60000);
  if (m<1) return 'just now'; if (m<60) return m+'m ago';
  const h = Math.floor(m/60); if (h<24) return h+'h ago';
  const dy = Math.floor(h/24); if (dy<7) return dy+'d ago';
  return new Date(ts).toLocaleDateString();
}

function renderClipCard(c) {
  const statusColor = c.status==='active' ? '#10b981' : '#64748b';
  const statusBg = c.status==='active' ? '#10b98122' : '#64748b22';
  const statusLabel = c.status==='active' ? '\u25cf ACTIVE' : '\u25e6 PARKED';
  let html = `<div class="clip">`;
  // Header
  html += `<div class="clip-hdr"><div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">`;
  html += `<span class="badge" style="background:${statusBg};color:${statusColor}" `
    + `onclick="toggleStatus('${c.id}')">${statusLabel}</span>`;
  html += `<span class="cat-badge">${esc(c.category)}</span>`;
  html += `</div><div style="display:flex;gap:6px;align-items:center">`;
  html += `<span style="font-size:11px;color:#64748b">${timeAgo(c.timestamp)}</span>`;
  html += `<button class="del-btn" onclick="delClip('${c.id}')">\u2715</button>`;
  html += `</div></div>`;
  // Image
  if (c.image) {
    html += `<img src="${c.image}" onclick="this.classList.toggle('expanded')" />`;
  }
  // Comment
  if (c.comment) html += `<div class="comment">${esc(c.comment)}</div>`;
  // AI summary
  if (c.aiSummary) html += `<div class="ai-summary">\u2728 ${esc(c.aiSummary)}</div>`;
  // Tags
  if (c.tags && c.tags.length) {
    html += `<div class="tags">${c.tags.map(t=>`<span class="tag">#${esc(t)}</span>`).join('')}</div>`;
  }
  // Thread comments
  if (c.comments && c.comments.length) {
    html += `<div class="thread">`;
    c.comments.forEach(x => {
      html += `<div class="thread-item">${esc(x.text)} <span class="ts">\u2014 ${timeAgo(x.ts)}</span></div>`;
    });
    html += `</div>`;
  }
  // Add comment button
  html += `<button class="add-comment-btn" onclick="showCommentInput('${c.id}')">+ Comment</button>`;
  html += `<div id="ci-${c.id}" style="display:none;margin-top:6px">`;
  html += `<input class="comment-input" id="cin-${c.id}" placeholder="Add a thought..." `
    + `onkeydown="if(event.key==='Enter')addComment('${c.id}');if(event.key==='Escape')hideCommentInput('${c.id}')" />`;
  html += `</div>`;
  html += `</div>`;
  return html;
}

function esc(s) {
  if (!s) return '';
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── Actions ──
async function toggleStatus(id) {
  const clip = clips.find(c => c.id === id);
  if (!clip) return;
  const newStatus = clip.status === 'active' ? 'parked' : 'active';
  await window.quickclip.updateClip(id, { status: newStatus });
  clip.status = newStatus;
  renderAll();
}

async function delClip(id) {
  await window.quickclip.deleteClip(id);
  clips = clips.filter(c => c.id !== id);
  renderAll();
}

function showCommentInput(id) {
  document.getElementById('ci-'+id).style.display = 'block';
  document.getElementById('cin-'+id).focus();
}
function hideCommentInput(id) {
  document.getElementById('ci-'+id).style.display = 'none';
}

async function addComment(id) {
  const input = document.getElementById('cin-'+id);
  const text = input.value.trim();
  if (!text) return;
  const clip = clips.find(c => c.id === id);
  if (!clip) return;
  if (!clip.comments) clip.comments = [];
  clip.comments.push({ text, ts: Date.now() });
  await window.quickclip.updateClip(id, { comments: clip.comments });
  input.value = '';
  hideCommentInput(id);
  renderAll();
}

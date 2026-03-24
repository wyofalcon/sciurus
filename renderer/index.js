// renderer/index.js — Main window: clip browser, filtering, AI search

// ── State ──

let clips = [];
let categories = [];
let filterCat = 'All';
let filterStatus = 'all';
let aiMatchedIds = null;
let searchQuery = '';

// ── Allowed update fields (prevents prototype pollution) ──

const ALLOWED_CLIP_FIELDS = ['category', 'tags', 'aiSummary', 'url', 'status', 'comments'];

// ── Init ──

(async () => {
  clips = await window.quickclip.getClips();
  categories = await window.quickclip.getCategories();
  const hasKey = await window.quickclip.hasApiKey();
  if (!hasKey) document.getElementById('noKeyBanner').style.display = 'block';
  renderAll();
})();

// Escape hides the main window to tray
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') window.quickclip.hideMain();
});

window.quickclip.onClipsUpdated((updated) => {
  clips = updated;
  renderAll();
});

// ── Escaping ──

/** Escape HTML entities for safe insertion into innerHTML. */
function esc(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
          .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Escape a string for safe use inside an HTML attribute (single-quoted). */
function escAttr(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/'/g, '&#39;')
          .replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/\\/g, '\\\\');
}

// ── AI ──

async function aiCategorize(clip) {
  document.getElementById('aiBar').style.display = 'flex';
  document.getElementById('aiBarMsg').textContent = 'AI categorizing...';
  try {
    const result = await window.quickclip.aiCategorize(clip.comment, clip.image);
    if (!result) return;

    const updates = {};
    if (result.category && clip.category === 'Uncategorized') updates.category = result.category;
    if (result.tags) updates.tags = result.tags;
    if (result.summary) updates.aiSummary = result.summary;
    if (result.url) updates.url = result.url;

    if (Object.keys(updates).length) {
      await window.quickclip.updateClip(clip.id, updates);
      for (const key of ALLOWED_CLIP_FIELDS) {
        if (key in updates) clip[key] = updates[key];
      }
      if (result.category && !categories.includes(result.category)) {
        categories.push(result.category);
        await window.quickclip.saveCategories(categories);
      }
      renderAll();
    }
  } catch (e) {
    console.error('[AI] Categorize failed:', e);
  } finally {
    document.getElementById('aiBar').style.display = 'none';
  }
}

async function doAiSearch() {
  searchQuery = document.getElementById('searchInput').value.trim();
  if (!searchQuery) { clearSearch(); return; }
  const btn = document.getElementById('aiSearchBtn');
  btn.disabled = true;
  btn.textContent = '...';
  try {
    aiMatchedIds = await window.quickclip.aiSearch(searchQuery);
  } catch (e) {
    console.error('[AI] Search failed:', e);
  } finally {
    btn.disabled = false;
    btn.textContent = '\u2728 AI Search';
    renderClips();
  }
}

function clearSearch() {
  aiMatchedIds = null;
  searchQuery = '';
  document.getElementById('searchInput').value = '';
  document.getElementById('aiResultBar').style.display = 'none';
  renderClips();
}

function openCapture() {
  window.quickclip.openCapture();
}

// ── Filters ──

function setCat(cat) {
  filterCat = cat;
  aiMatchedIds = null;
  renderAll();
}

function setStatus(status) {
  filterStatus = status;
  document.querySelectorAll('[data-status]').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.status === status);
  });
  renderClips();
}

/** Apply active filters and search to the clip list. */
function getFiltered() {
  let filtered = clips;
  if (filterCat !== 'All') filtered = filtered.filter((c) => c.category === filterCat);
  if (filterStatus !== 'all') filtered = filtered.filter((c) => c.status === filterStatus);
  if (aiMatchedIds) {
    filtered = filtered.filter((c) => aiMatchedIds.includes(c.id));
  } else if (searchQuery) {
    const q = searchQuery.toLowerCase();
    filtered = filtered.filter((c) =>
      (c.comment || '').toLowerCase().includes(q) ||
      (c.category || '').toLowerCase().includes(q) ||
      (c.tags || []).some((t) => t.toLowerCase().includes(q)) ||
      (c.aiSummary || '').toLowerCase().includes(q) ||
      (c.comments || []).some((x) => x.text.toLowerCase().includes(q))
    );
  }
  return filtered;
}

// ── Rendering ──

function renderAll() {
  renderSidebar();
  renderClips();
  const parked = clips.filter((c) => c.status === 'parked').length;
  const sub = `Screenshot \u2192 Comment \u2192 Done. AI handles the rest. \u2014 ${clips.length} clips`
    + (parked > 0 ? ` \u00b7 ${parked} parked` : '');
  document.getElementById('subtitle').textContent = sub;
}

function renderSidebar() {
  const list = document.getElementById('catList');
  const allCats = ['All', ...categories.filter((c) => c !== 'Uncategorized')];
  list.innerHTML = allCats.map((cat) => {
    const count = cat === 'All' ? clips.length : clips.filter((c) => c.category === cat).length;
    if (cat !== 'All' && count === 0) return '';
    const active = filterCat === cat ? 'active' : '';
    return `<button class="sb-btn ${active}" onclick="setCat('${escAttr(cat)}')">`
      + `<span>${esc(cat)}</span><span class="sb-count">${count}</span></button>`;
  }).join('');
}

function renderClips() {
  const filtered = getFiltered();
  const bar = document.getElementById('aiResultBar');
  if (aiMatchedIds) {
    bar.style.display = 'flex';
    document.getElementById('aiResultText').textContent =
      `\u2728 ${filtered.length} result${filtered.length !== 1 ? 's' : ''}`;
  } else {
    bar.style.display = 'none';
  }
  const el = document.getElementById('clipList');
  if (filtered.length === 0) {
    const isEmpty = clips.length === 0;
    el.innerHTML = `<div class="empty"><div class="ico">\u26a1</div>`
      + `<div class="empty-title">${isEmpty ? 'No clips yet' : 'No matches'}</div>`
      + `<div class="empty-sub">${isEmpty ? 'Take a screenshot \u2014 capture pops automatically' : 'Try a different search'}</div></div>`;
    return;
  }
  el.innerHTML = filtered.map((c) => renderClipCard(c)).join('');
}

/** Format a timestamp as a relative time string. */
function timeAgo(ts) {
  const ms = Date.now() - ts;
  const mins = Math.floor(ms / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + 'm ago';
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return hrs + 'h ago';
  const days = Math.floor(hrs / 24);
  if (days < 7) return days + 'd ago';
  return new Date(ts).toLocaleDateString();
}

/** Build the HTML for a single clip card. */
function renderClipCard(c) {
  const id = escAttr(c.id);
  const isActive = c.status === 'active';
  const statusClass = isActive ? 'badge-active' : 'badge-parked';
  const statusLabel = isActive ? '\u25cf ACTIVE' : '\u25e6 PARKED';

  let html = `<div class="clip">`;

  // Header row
  html += `<div class="clip-hdr">`;
  html += `<div class="clip-meta">`;
  html += `<span class="badge ${statusClass}" onclick="toggleStatus('${id}')">${statusLabel}</span>`;
  html += `<span class="cat-badge">${esc(c.category)}</span>`;
  html += `</div>`;
  html += `<div class="clip-actions">`;
  html += `<span class="clip-time">${timeAgo(c.timestamp)}</span>`;
  html += `<button class="del-btn" onclick="deleteClip('${id}')">\u2715</button>`;
  html += `</div></div>`;

  // Screenshot
  if (c.image) {
    html += `<img src="${esc(c.image)}" onclick="this.classList.toggle('expanded')" />`;
  }

  // Comment
  if (c.comment) html += `<div class="comment">${esc(c.comment)}</div>`;

  // AI summary
  if (c.aiSummary) html += `<div class="ai-summary">\u2728 ${esc(c.aiSummary)}</div>`;

  // Tags
  if (c.tags && c.tags.length) {
    html += `<div class="tags">${c.tags.map((t) => `<span class="tag">#${esc(t)}</span>`).join('')}</div>`;
  }

  // Thread comments
  if (c.comments && c.comments.length) {
    html += `<div class="thread">`;
    c.comments.forEach((x) => {
      html += `<div class="thread-item">${esc(x.text)} <span class="ts">\u2014 ${timeAgo(x.ts)}</span></div>`;
    });
    html += `</div>`;
  }

  // Add comment input
  html += `<button class="add-comment-btn" onclick="showCommentInput('${id}')">+ Comment</button>`;
  html += `<div id="ci-${id}" style="display:none;margin-top:6px">`;
  html += `<input class="comment-input" id="cin-${id}" placeholder="Add a thought..." `
    + `onkeydown="if(event.key==='Enter')addComment('${id}');if(event.key==='Escape')hideCommentInput('${id}')" />`;
  html += `</div></div>`;

  return html;
}

// ── Actions ──

async function toggleStatus(id) {
  const clip = clips.find((c) => c.id === id);
  if (!clip) return;
  const newStatus = clip.status === 'active' ? 'parked' : 'active';
  await window.quickclip.updateClip(id, { status: newStatus });
  clip.status = newStatus;
  renderAll();
}

async function deleteClip(id) {
  await window.quickclip.deleteClip(id);
  clips = clips.filter((c) => c.id !== id);
  renderAll();
}

function showCommentInput(id) {
  document.getElementById('ci-' + id).style.display = 'block';
  document.getElementById('cin-' + id).focus();
}

function hideCommentInput(id) {
  document.getElementById('ci-' + id).style.display = 'none';
}

async function addComment(id) {
  const input = document.getElementById('cin-' + id);
  const text = input.value.trim();
  if (!text) return;
  const clip = clips.find((c) => c.id === id);
  if (!clip) return;
  if (!clip.comments) clip.comments = [];
  clip.comments.push({ text, ts: Date.now() });
  await window.quickclip.updateClip(id, { comments: clip.comments });
  input.value = '';
  hideCommentInput(id);
  renderAll();
}

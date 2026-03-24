// renderer/index.js — Main window: tabbed notes viewer, projects, settings

// ── State ──

let activeTab = 'general';
let clips = [];
let categories = [];
let projects = [];
let settings = {};

// General Notes tab state
let filterCat = 'All';
let filterStatus = 'all';
let aiMatchedIds = null;
let searchQuery = '';

// Projects tab state
let selectedProjectId = null;

// ── Init ──

(async () => {
  const hasKey = await window.quickclip.hasApiKey();
  if (!hasKey) document.getElementById('noKeyBanner').style.display = 'block';
  await loadData();
  renderAll();
})();

async function loadData() {
  [clips, categories, projects, settings] = await Promise.all([
    window.quickclip.getClips(),
    window.quickclip.getCategories(),
    window.quickclip.getProjects(),
    window.quickclip.getSettings(),
  ]);
}

// Escape hides the main window to tray
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') window.quickclip.hideMain();
});

window.quickclip.onClipsChanged(async () => {
  clips = await window.quickclip.getClips();
  if (activeTab === 'general' || activeTab === 'projects') renderContent();
  updateStatusBar();
});

window.quickclip.onProjectsChanged(async () => {
  projects = await window.quickclip.getProjects();
  if (activeTab === 'projects') renderAll();
});

// ── Escaping ──

function esc(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
          .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function escAttr(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/'/g, '&#39;')
          .replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/\\/g, '\\\\');
}

// ── Tab Switching ──

function switchTab(tab) {
  activeTab = tab;
  document.querySelectorAll('.tab').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.tab === tab);
  });
  renderAll();
}

// ── Actions ──

function openCapture() {
  window.quickclip.openCapture();
}

// ── Time Formatting ──

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

// ── Rendering Entry Point ──

function renderAll() {
  renderSidebar();
  renderContent();
  updateStatusBar();
}

function updateStatusBar() {
  const sub = document.getElementById('subtitle');
  if (activeTab === 'general') {
    const generalClips = clips.filter((c) => !c.project_id);
    const parked = generalClips.filter((c) => c.status === 'parked').length;
    sub.textContent = `${generalClips.length} general notes` + (parked > 0 ? ` · ${parked} parked` : '');
  } else if (activeTab === 'projects') {
    sub.textContent = `${projects.length} project${projects.length !== 1 ? 's' : ''} · ${clips.length} total clips`;
  } else {
    sub.textContent = 'App settings';
  }
}

// =====================================================================
//  SIDEBAR
// =====================================================================

function renderSidebar() {
  const el = document.getElementById('sidebar');
  if (activeTab === 'general') renderGeneralSidebar(el);
  else if (activeTab === 'projects') renderProjectsSidebar(el);
  else if (activeTab === 'settings') renderSettingsSidebar(el);
}

function renderGeneralSidebar(el) {
  const generalClips = clips.filter((c) => !c.project_id);
  const allCats = ['All', ...categories.filter((c) => c !== 'Uncategorized')];

  let html = '<div class="sec">Categories</div>';
  allCats.forEach((cat) => {
    const count = cat === 'All' ? generalClips.length : generalClips.filter((c) => c.category === cat).length;
    if (cat !== 'All' && count === 0) return;
    const active = filterCat === cat ? 'active' : '';
    html += `<button class="sb-btn ${active}" onclick="setCat('${escAttr(cat)}')">`
      + `<span>${esc(cat)}</span><span class="sb-count">${count}</span></button>`;
  });

  html += '<div class="sec">Status</div>';
  ['all', 'parked', 'active'].forEach((s) => {
    const label = s === 'all' ? 'All' : s.charAt(0).toUpperCase() + s.slice(1);
    html += `<button class="sb-btn ${filterStatus === s ? 'active' : ''}" onclick="setStatus('${s}')">${label}</button>`;
  });

  el.innerHTML = html;
}

function renderProjectsSidebar(el) {
  let html = '<div class="sec">Projects</div>';
  html += `<button class="sb-btn ${selectedProjectId === null ? 'active' : ''}" onclick="selectProject(null)">
    <span>All Projects</span><span class="sb-count">${projects.length}</span></button>`;

  projects.forEach((p) => {
    const active = selectedProjectId === p.id ? 'active' : '';
    html += `<button class="sb-btn ${active}" onclick="selectProject(${p.id})" style="${selectedProjectId === p.id ? 'border-left:3px solid ' + esc(p.color) : ''}">
      <span><span class="proj-dot" style="background:${esc(p.color)}"></span>${esc(p.name)}</span>
      <span class="sb-count">${p.clipCount || 0}</span></button>`;
  });

  html += `<button class="sb-btn sb-add" onclick="showNewProjectDialog()">+ New Project</button>`;
  el.innerHTML = html;
}

function renderSettingsSidebar(el) {
  el.innerHTML = `
    <div class="sec">Settings</div>
    <button class="sb-btn active">All Settings</button>
  `;
}

// =====================================================================
//  MAIN CONTENT
// =====================================================================

function renderContent() {
  const el = document.getElementById('mainArea');
  if (activeTab === 'general') renderGeneralContent(el);
  else if (activeTab === 'projects') renderProjectsContent(el);
  else if (activeTab === 'settings') renderSettingsContent(el);
}

// ── General Notes ──

function renderGeneralContent(el) {
  let html = `<div class="search-bar">
    <input id="searchInput" placeholder='Search or ask "that paste thing for Marcus"'
      value="${escAttr(searchQuery)}"
      onkeydown="if(event.key==='Enter')doAiSearch()" />
    <button type="button" class="ai-btn" id="aiSearchBtn" onclick="doAiSearch()">AI Search</button>
  </div>`;

  if (aiMatchedIds) {
    html += `<div class="ai-result-bar"><span id="aiResultText"></span>
      <button type="button" class="clear-btn" onclick="clearSearch()">Clear</button></div>`;
  }

  const filtered = getFilteredGeneral();

  if (aiMatchedIds) {
    // We need to update the result count after rendering
    setTimeout(() => {
      const rt = document.getElementById('aiResultText');
      if (rt) rt.textContent = `${filtered.length} result${filtered.length !== 1 ? 's' : ''}`;
    });
  }

  if (filtered.length === 0) {
    const isEmpty = clips.filter((c) => !c.project_id).length === 0;
    html += `<div class="empty"><div class="ico">&#x26a1;</div>`
      + `<div class="empty-title">${isEmpty ? 'No notes yet' : 'No matches'}</div>`
      + `<div class="empty-sub">${isEmpty ? 'Take a screenshot — capture pops automatically' : 'Try a different search'}</div></div>`;
  } else {
    html += filtered.map((c) => renderClipCard(c)).join('');
  }

  el.innerHTML = html;
}

function getFilteredGeneral() {
  let filtered = clips.filter((c) => !c.project_id);
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

function setCat(cat) {
  filterCat = cat;
  aiMatchedIds = null;
  renderAll();
}

function setStatus(status) {
  filterStatus = status;
  renderAll();
}

async function doAiSearch() {
  const input = document.getElementById('searchInput');
  searchQuery = input ? input.value.trim() : '';
  if (!searchQuery) { clearSearch(); return; }
  const btn = document.getElementById('aiSearchBtn');
  if (btn) { btn.disabled = true; btn.textContent = '...'; }
  try {
    aiMatchedIds = await window.quickclip.aiSearch(searchQuery);
  } catch (e) {
    console.error('[AI] Search failed:', e);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'AI Search'; }
    renderContent();
  }
}

function clearSearch() {
  aiMatchedIds = null;
  searchQuery = '';
  renderAll();
}

// ── Projects Content ──

function renderProjectsContent(el) {
  if (selectedProjectId === null) {
    renderProjectsList(el);
  } else {
    renderProjectDetail(el);
  }
}

function renderProjectsList(el) {
  if (projects.length === 0) {
    el.innerHTML = `<div class="empty">
      <div class="ico">&#x1F4C1;</div>
      <div class="empty-title">No projects yet</div>
      <div class="empty-sub">Create a project to organize notes by topic or repo</div>
      <button class="cap-btn" style="margin-top:16px" onclick="showNewProjectDialog()">+ New Project</button>
    </div>`;
    return;
  }

  let html = `<div class="projects-header">
    <h2>All Projects</h2>
    <button class="cap-btn small" onclick="showNewProjectDialog()">+ New Project</button>
  </div>`;
  html += '<div class="projects-grid">';
  projects.forEach((p) => {
    html += `<div class="project-card" onclick="selectProject(${p.id})" style="border-left-color:${esc(p.color)}">
      <div class="project-card-name">${esc(p.name)}</div>
      <div class="project-card-desc">${esc(p.description) || 'No description'}</div>
      <div class="project-card-meta">${p.clipCount || 0} clips${p.repo_path ? ' · ' + esc(p.repo_path) : ''}</div>
    </div>`;
  });
  html += '</div>';
  el.innerHTML = html;
}

function renderProjectDetail(el) {
  const proj = projects.find((p) => p.id === selectedProjectId);
  if (!proj) { selectProject(null); return; }

  const projectClips = clips.filter((c) => c.project_id === selectedProjectId);

  let html = `<div class="project-detail-header">
    <div>
      <button class="back-btn" onclick="selectProject(null)">&larr; All Projects</button>
      <h2 style="display:inline;margin-left:8px"><span class="proj-dot big" style="background:${esc(proj.color)}"></span>${esc(proj.name)}</h2>
    </div>
    <div class="project-detail-actions">
      <button class="sb-btn-action" onclick="editProject(${proj.id})">Edit</button>
      <button class="sb-btn-action danger" onclick="confirmDeleteProject(${proj.id})">Delete</button>
    </div>
  </div>`;

  if (proj.description) {
    html += `<div class="project-desc">${esc(proj.description)}</div>`;
  }
  if (proj.repo_path) {
    html += `<div class="project-repo">${esc(proj.repo_path)}</div>`;
  }

  html += `<div class="search-bar" style="margin-top:12px">
    <input id="projectSearchInput" placeholder="Search in project..."
      onkeydown="if(event.key==='Enter')searchProject()" oninput="searchProject()" />
  </div>`;

  if (projectClips.length === 0) {
    html += `<div class="empty"><div class="ico">&#x1F4DD;</div>
      <div class="empty-title">No clips in this project</div>
      <div class="empty-sub">Assign clips from General Notes or capture new ones</div></div>`;
  } else {
    html += projectClips.map((c) => renderClipCard(c, true)).join('');
  }

  el.innerHTML = html;
}

function searchProject() {
  const input = document.getElementById('projectSearchInput');
  if (!input) return;
  const q = input.value.trim().toLowerCase();
  const el = document.getElementById('mainArea');
  // Re-render with filter (simple approach: re-render all)
  const proj = projects.find((p) => p.id === selectedProjectId);
  if (!proj) return;

  let projectClips = clips.filter((c) => c.project_id === selectedProjectId);
  if (q) {
    projectClips = projectClips.filter((c) =>
      (c.comment || '').toLowerCase().includes(q) ||
      (c.category || '').toLowerCase().includes(q) ||
      (c.tags || []).some((t) => t.toLowerCase().includes(q)) ||
      (c.aiSummary || '').toLowerCase().includes(q) ||
      (c.comments || []).some((x) => x.text.toLowerCase().includes(q))
    );
  }

  const clipListHtml = projectClips.length > 0
    ? projectClips.map((c) => renderClipCard(c, true)).join('')
    : `<div class="empty"><div class="empty-title">No matches</div></div>`;

  // Replace clip list only (find after search-bar)
  const searchBarEnd = el.innerHTML.lastIndexOf('</div><!--cliplist-->');
  // Simpler approach: just rebuild the clip area
  const container = el.querySelectorAll('.clip, .empty');
  container.forEach((node) => node.remove());

  const wrapper = document.createElement('div');
  wrapper.innerHTML = clipListHtml;
  while (wrapper.firstChild) el.appendChild(wrapper.firstChild);
}

function selectProject(id) {
  selectedProjectId = id;
  renderAll();
}

// ── Project CRUD ──

function showNewProjectDialog() {
  const el = document.getElementById('mainArea');
  const existing = document.getElementById('projectDialog');
  if (existing) { existing.remove(); return; }

  const dialog = document.createElement('div');
  dialog.id = 'projectDialog';
  dialog.className = 'project-dialog';
  dialog.innerHTML = `
    <h3>New Project</h3>
    <label class="field-label">Name</label>
    <input id="projName" class="field-input" placeholder="e.g. Cvstomize" onkeydown="if(event.key==='Enter')saveNewProject()" />
    <label class="field-label">Description</label>
    <input id="projDesc" class="field-input" placeholder="What is this project about?" />
    <label class="field-label">Repo Path <span class="field-hint">— optional, for auto-detect</span></label>
    <input id="projRepo" class="field-input" placeholder="C:\\Users\\..." />
    <label class="field-label">Color</label>
    <div class="color-picker">
      <button class="color-dot active" style="background:#3b82f6" onclick="pickColor(this,'#3b82f6')"></button>
      <button class="color-dot" style="background:#8b5cf6" onclick="pickColor(this,'#8b5cf6')"></button>
      <button class="color-dot" style="background:#10b981" onclick="pickColor(this,'#10b981')"></button>
      <button class="color-dot" style="background:#f59e0b" onclick="pickColor(this,'#f59e0b')"></button>
      <button class="color-dot" style="background:#ef4444" onclick="pickColor(this,'#ef4444')"></button>
      <button class="color-dot" style="background:#ec4899" onclick="pickColor(this,'#ec4899')"></button>
      <button class="color-dot" style="background:#06b6d4" onclick="pickColor(this,'#06b6d4')"></button>
      <button class="color-dot" style="background:#84cc16" onclick="pickColor(this,'#84cc16')"></button>
    </div>
    <div class="dialog-actions">
      <button class="cap-btn small" onclick="saveNewProject()">Create</button>
      <button class="cancel-btn" onclick="document.getElementById('projectDialog').remove()">Cancel</button>
    </div>
  `;
  el.prepend(dialog);
  document.getElementById('projName').focus();
}

let newProjectColor = '#3b82f6';

function pickColor(btn, color) {
  newProjectColor = color;
  document.querySelectorAll('.color-dot').forEach((d) => d.classList.remove('active'));
  btn.classList.add('active');
}

async function saveNewProject() {
  const name = document.getElementById('projName').value.trim();
  if (!name) return;
  const desc = document.getElementById('projDesc').value.trim();
  const repo = document.getElementById('projRepo').value.trim();
  await window.quickclip.createProject({
    name,
    description: desc,
    repo_path: repo || null,
    color: newProjectColor,
  });
  projects = await window.quickclip.getProjects();
  newProjectColor = '#3b82f6';
  renderAll();
}

function editProject(id) {
  const proj = projects.find((p) => p.id === id);
  if (!proj) return;

  const el = document.getElementById('mainArea');
  const existing = document.getElementById('projectDialog');
  if (existing) existing.remove();

  const dialog = document.createElement('div');
  dialog.id = 'projectDialog';
  dialog.className = 'project-dialog';
  dialog.innerHTML = `
    <h3>Edit Project</h3>
    <label class="field-label">Name</label>
    <input id="editProjName" class="field-input" value="${escAttr(proj.name)}" />
    <label class="field-label">Description</label>
    <input id="editProjDesc" class="field-input" value="${escAttr(proj.description)}" />
    <label class="field-label">Repo Path</label>
    <input id="editProjRepo" class="field-input" value="${escAttr(proj.repo_path || '')}" />
    <label class="field-label">Color</label>
    <div class="color-picker">
      ${['#3b82f6','#8b5cf6','#10b981','#f59e0b','#ef4444','#ec4899','#06b6d4','#84cc16'].map((c) =>
        `<button class="color-dot ${proj.color === c ? 'active' : ''}" style="background:${c}" onclick="pickEditColor(this,'${c}')"></button>`
      ).join('')}
    </div>
    <div class="dialog-actions">
      <button class="cap-btn small" onclick="saveEditProject(${id})">Save</button>
      <button class="cancel-btn" onclick="document.getElementById('projectDialog').remove()">Cancel</button>
    </div>
  `;
  el.prepend(dialog);
  document.getElementById('editProjName').focus();
}

let editProjectColor = null;

function pickEditColor(btn, color) {
  editProjectColor = color;
  document.querySelectorAll('.color-dot').forEach((d) => d.classList.remove('active'));
  btn.classList.add('active');
}

async function saveEditProject(id) {
  const name = document.getElementById('editProjName').value.trim();
  if (!name) return;
  const desc = document.getElementById('editProjDesc').value.trim();
  const repo = document.getElementById('editProjRepo').value.trim();
  const proj = projects.find((p) => p.id === id);
  await window.quickclip.updateProject(id, {
    name,
    description: desc,
    repo_path: repo || null,
    color: editProjectColor || (proj ? proj.color : '#3b82f6'),
  });
  projects = await window.quickclip.getProjects();
  editProjectColor = null;
  renderAll();
}

async function confirmDeleteProject(id) {
  const proj = projects.find((p) => p.id === id);
  if (!proj) return;
  // Simple confirm via re-rendering with a confirm banner
  const confirmed = confirm(`Delete project "${proj.name}"?\n\nClips will be moved to General Notes.`);
  if (!confirmed) return;
  await window.quickclip.deleteProject(id);
  projects = await window.quickclip.getProjects();
  clips = await window.quickclip.getClips();
  selectedProjectId = null;
  renderAll();
}

// ── Settings Content ──

function renderSettingsContent(el) {
  const general = settings.general || { openWindowOnLaunch: true, minimizeToTray: true, theme: 'dark' };
  const capture = settings.capture || { hotkey: 'ctrl+shift+q', watchClipboard: true, pollInterval: 500, autoCategory: true };
  const aiSettings = settings.ai || { enabled: true, autoCategorizeonSave: true, retryUncategorizedOnStartup: true };

  el.innerHTML = `
    <div class="settings-page">
      <h2>Settings</h2>

      <div class="settings-section">
        <h3>General</h3>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Open window on launch</div>
            <div class="setting-desc">Show the main window when Sciurus starts</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${general.openWindowOnLaunch ? 'checked' : ''} onchange="updateSetting('general','openWindowOnLaunch',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Minimize to tray</div>
            <div class="setting-desc">Hide to system tray instead of closing</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${general.minimizeToTray ? 'checked' : ''} onchange="updateSetting('general','minimizeToTray',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Theme</div>
            <div class="setting-desc">Color theme for the app</div>
          </div>
          <select class="setting-select" onchange="updateSetting('general','theme',this.value)">
            <option value="dark" ${general.theme === 'dark' ? 'selected' : ''}>Dark</option>
            <option value="light" ${general.theme === 'light' ? 'selected' : ''}>Light</option>
          </select>
        </div>
      </div>

      <div class="settings-section">
        <h3>Capture</h3>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Hotkey</div>
            <div class="setting-desc">Keyboard shortcut for quick capture</div>
          </div>
          <input class="setting-input" value="${escAttr(capture.hotkey)}" onchange="updateSetting('capture','hotkey',this.value)" />
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Watch clipboard</div>
            <div class="setting-desc">Auto-detect screenshots from clipboard</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${capture.watchClipboard ? 'checked' : ''} onchange="updateSetting('capture','watchClipboard',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Poll interval (ms)</div>
            <div class="setting-desc">How often to check the clipboard for new screenshots</div>
          </div>
          <input class="setting-input" type="number" value="${capture.pollInterval}" onchange="updateSetting('capture','pollInterval',parseInt(this.value))" />
        </div>
      </div>

      <div class="settings-section">
        <h3>AI</h3>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">AI enabled</div>
            <div class="setting-desc">Enable Gemini AI for categorization and search</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${aiSettings.enabled ? 'checked' : ''} onchange="updateSetting('ai','enabled',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Auto-categorize on save</div>
            <div class="setting-desc">Automatically run AI categorization when a clip is saved</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${aiSettings.autoCategorizeonSave ? 'checked' : ''} onchange="updateSetting('ai','autoCategorizeonSave',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Retry uncategorized on startup</div>
            <div class="setting-desc">Re-attempt AI categorization for unsorted clips when app starts</div>
          </div>
          <label class="toggle">
            <input type="checkbox" ${aiSettings.retryUncategorizedOnStartup ? 'checked' : ''} onchange="updateSetting('ai','retryUncategorizedOnStartup',this.checked)">
            <span class="toggle-slider"></span>
          </label>
        </div>
      </div>

      <div class="settings-section">
        <h3>Database</h3>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Status</div>
            <div class="setting-desc">PostgreSQL connection via Docker</div>
          </div>
          <span class="setting-badge ok">Connected</span>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Total clips</div>
            <div class="setting-desc">Across all projects and general notes</div>
          </div>
          <span class="setting-value">${clips.length}</span>
        </div>
        <div class="setting-row">
          <div class="setting-info">
            <div class="setting-label">Projects</div>
            <div class="setting-desc">Active project count</div>
          </div>
          <span class="setting-value">${projects.length}</span>
        </div>
      </div>
    </div>
  `;
}

async function updateSetting(section, key, value) {
  const current = settings[section] || {};
  current[key] = value;
  settings[section] = current;
  await window.quickclip.saveSetting(section, current);
}

// =====================================================================
//  CLIP CARD
// =====================================================================

function renderClipCard(c, inProject) {
  const id = escAttr(c.id);
  const isActive = c.status === 'active';
  const statusClass = isActive ? 'badge-active' : 'badge-parked';
  const statusLabel = isActive ? 'ACTIVE' : 'PARKED';

  let html = `<div class="clip">`;

  // Header row
  html += `<div class="clip-hdr">`;
  html += `<div class="clip-meta">`;
  html += `<span class="badge ${statusClass}" onclick="toggleStatus('${id}')">${statusLabel}</span>`;
  html += `<span class="cat-badge">${esc(c.category)}</span>`;
  if (c.projectName && !inProject) {
    html += `<span class="proj-badge" style="border-color:${esc(c.projectColor || '#3b82f6')}">${esc(c.projectName)}</span>`;
  }
  html += `</div>`;
  html += `<div class="clip-actions">`;
  html += `<span class="clip-time">${timeAgo(c.timestamp)}</span>`;

  // Move to project dropdown
  if (!inProject && projects.length > 0) {
    html += `<select class="move-select" onchange="moveToProject('${id}', this.value)" title="Move to project">`;
    html += `<option value="">Move...</option>`;
    projects.forEach((p) => {
      html += `<option value="${p.id}">${esc(p.name)}</option>`;
    });
    html += `</select>`;
  }
  if (inProject) {
    html += `<button class="del-btn" onclick="unassignClip('${id}')" title="Move to General Notes">&#x2190;</button>`;
  }

  html += `<button class="del-btn" onclick="deleteClip('${id}')">&#x2715;</button>`;
  html += `</div></div>`;

  // Screenshot
  if (c.image) {
    html += `<img src="${esc(c.image)}" onclick="this.classList.toggle('expanded')" />`;
  }

  // Comment
  if (c.comment) html += `<div class="comment">${esc(c.comment)}</div>`;

  // AI summary
  if (c.aiSummary) html += `<div class="ai-summary">${esc(c.aiSummary)}</div>`;

  // Tags
  if (c.tags && c.tags.length) {
    html += `<div class="tags">${c.tags.map((t) => `<span class="tag">#${esc(t)}</span>`).join('')}</div>`;
  }

  // Thread comments
  if (c.comments && c.comments.length) {
    html += `<div class="thread">`;
    c.comments.forEach((x) => {
      html += `<div class="thread-item">${esc(x.text)} <span class="ts">— ${timeAgo(x.ts)}</span></div>`;
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

// ── Clip Actions ──

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

async function moveToProject(clipId, projectId) {
  if (!projectId) return;
  await window.quickclip.assignClipToProject(clipId, parseInt(projectId));
  clips = await window.quickclip.getClips();
  projects = await window.quickclip.getProjects();
  renderAll();
}

async function unassignClip(clipId) {
  await window.quickclip.assignClipToProject(clipId, null);
  clips = await window.quickclip.getClips();
  projects = await window.quickclip.getProjects();
  renderAll();
}

function showCommentInput(id) {
  const el = document.getElementById('ci-' + id);
  if (el) { el.style.display = 'block'; document.getElementById('cin-' + id).focus(); }
}

function hideCommentInput(id) {
  const el = document.getElementById('ci-' + id);
  if (el) el.style.display = 'none';
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

// ── AI Manual Categorize ──

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
      clips = await window.quickclip.getClips();
      categories = await window.quickclip.getCategories();
      renderAll();
    }
  } catch (e) {
    console.error('[AI] Categorize failed:', e);
  } finally {
    document.getElementById('aiBar').style.display = 'none';
  }
}

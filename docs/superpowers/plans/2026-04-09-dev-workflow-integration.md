# Dev Workflow Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform HuminLoop into the context aggregation and delivery layer for a multi-agent AI dev workflow, with Focused mode (renamed from Lite) as the primary dev interface.

**Architecture:** HuminLoop bundles screenshots, annotations, git state, and session data into structured prompts delivered via file bridge to the Architect agent (Claude Code in VS Code). No new AI API costs — context bundling is pure file reads plus the existing Gemini annotation interpretation. Workflow scaffolding ships as bundled templates; IDE connection targets VS Code + Claude Code extension via `.vscode/mcp.json`.

**Tech Stack:** Electron (main + renderer), Node.js, better-sqlite3/PostgreSQL, MCP SDK (stdio), Gemini 2.5 Flash (existing)

---

## Task 1: Data Migration — Lite → Focused Rename (DB + Settings)

**Files:**
- Modify: `src/main.js:1-30` (add migration near top, after DB init)
- Modify: `src/db.js` (if needed for raw query access)

This task handles the database-level rename so all subsequent tasks can use "focused" naming from the start.

- [ ] **Step 1: Add migration function to main.js**

After the DB is initialized (after `await db.init()` call), add:

```javascript
async function migrateV2() {
  const done = await db.getSettings('migration_v2_done');
  if (done) return;

  console.log('[HuminLoop] Running v1 → v2 migration...');

  // Migrate app_mode setting
  const mode = await db.getSettings('app_mode');
  if (mode === 'lite') {
    await db.saveSetting('app_mode', 'focused');
  }

  // Migrate lite_active_project → focused_active_project
  const liteProject = await db.getSettings('lite_active_project');
  if (liteProject) {
    await db.saveSetting('focused_active_project', liteProject);
    await db.saveSetting('lite_active_project', null);
  }

  // Migrate clip source field
  await db.runRaw?.(`UPDATE clips SET source = 'focused' WHERE source = 'lite'`)
    || console.log('[HuminLoop] Clip source migration requires manual DB update');

  await db.saveSetting('migration_v2_done', true);
  console.log('[HuminLoop] v2 migration complete');
}
```

- [ ] **Step 2: Add `runRaw` to db.js, db-sqlite.js, and db-pg.js**

In `db-sqlite.js`:
```javascript
function runRaw(sql, params = []) {
  return db.prepare(sql).run(...params);
}
```

In `db-pg.js`:
```javascript
async function runRaw(sql, params = []) {
  return pool.query(sql, params);
}
```

In `db.js`, delegate:
```javascript
runRaw: (...args) => backend.runRaw?.(...args),
```

- [ ] **Step 3: Call migration on startup**

In main.js, inside the app `ready` handler, after `await db.init()` and before `ai.init()`:

```javascript
await migrateV2();
```

- [ ] **Step 4: Update all "lite" references in main.js**

Rename throughout main.js:
- `getAppMode()` return value check: `=== 'lite'` → `=== 'focused'`
- `clip.source = 'lite'` → `clip.source = 'focused'`
- `db.getSettings('lite_active_project')` → `db.getSettings('focused_active_project')`
- `db.getClips(projectId, 'lite')` → `db.getClips(projectId, 'focused')`
- `autoCategorizeLite` → `autoCategorizeFocused`
- `mode === 'lite'` checks → `mode === 'focused'`
- IPC handler `'set-lite-active-project'` → `'set-focused-active-project'`
- IPC handler `'get-lite-clips'` → `'get-focused-clips'`
- `toggleAppMode`: `'lite'` string → `'focused'`

- [ ] **Step 5: Update preload.js**

Rename:
- `getLiteClips` → `getFocusedClips` (invokes `'get-focused-clips'`)
- `setLiteActiveProject` → `setFocusedActiveProject` (invokes `'set-focused-active-project'`)

Keep old names as aliases for one release cycle if desired, or remove since this is a major version.

- [ ] **Step 6: Update ai.js**

- Rename `LITE_PROMPT` → `FOCUSED_PROMPT`
- Rename `generateLitePrompt` → `generateFocusedPrompt`
- Update the export at the bottom of the file

- [ ] **Step 7: Update renderer/index.js**

- `isLiteMode` → `isFocusedMode`
- `mode === 'lite'` → `mode === 'focused'`
- `applyLiteMode()` → `applyFocusedMode()`
- `'Lite Mode'` label text → `'Focused'`
- All `window.quickclip.getLiteClips()` → `window.quickclip.getFocusedClips()`
- All `window.quickclip.setLiteActiveProject()` → `window.quickclip.setFocusedActiveProject()`
- Help page text: replace all "Lite Mode" references with "Focused Mode"

- [ ] **Step 8: Rename lite-capture.html → focused-capture.html**

- Rename the file
- Update the `BrowserWindow` creation in main.js that loads `lite-capture.html` to load `focused-capture.html`
- Inside the HTML file, update any visible "Lite" text to "Focused"
- If there's a `renderer/lite-capture.js`, rename to `renderer/focused-capture.js` and update the HTML script src

- [ ] **Step 9: Update api-server.js**

Any references to `'lite'` source filtering → `'focused'`

- [ ] **Step 10: Update mcp-server/index.js**

Any references to lite mode or lite source → focused

- [ ] **Step 11: Update PROMPT_TRACKER.log parsers to include files field**

In main.js `get-workflow-prompts` handler, update the parser:
```javascript
return { id: parts[0], status: parts[1], timestamp: parts[2], description: parts[3],
  type: parts[4] || 'CRAFTED', parentId: parts[5] || null,
  files: parts[6] ? parts[6].split(',').filter(Boolean) : [] };
```

In api-server.js `/api/workflow/prompts` GET handler, same change to the parser.

- [ ] **Step 12: Test and commit**

Run: `npm start` — verify the app launches, Focused mode works, existing clips migrated.

```bash
git add -A
git commit -m "refactor: rename Lite Mode to Focused Mode with v2 data migration"
```

---

## Task 2: Extend workflow-context.js — Git State, Prompt Parsing, Relay Mode

**Files:**
- Modify: `src/workflow-context.js`

This task makes workflow-context.js the single source of truth for all workflow state reads.

- [ ] **Step 1: Add getGitState()**

```javascript
const { execSync } = require('child_process');

function getGitState(repoPath) {
  if (!repoPath) return null;
  try {
    const opts = { cwd: repoPath, encoding: 'utf8', timeout: 5000 };
    const branch = execSync('git rev-parse --abbrev-ref HEAD', opts).trim();
    const logRaw = execSync('git log --oneline -5', opts).trim();
    const lastCommits = logRaw ? logRaw.split('\n').map(line => {
      const [hash, ...rest] = line.split(' ');
      return { hash, message: rest.join(' ') };
    }) : [];
    const statusRaw = execSync('git status --porcelain', opts).trim();
    const dirtyFiles = statusRaw ? statusRaw.split('\n').map(line => ({
      status: line.substring(0, 2).trim(),
      file: line.substring(3),
    })) : [];
    return { branch, lastCommits, dirtyFiles };
  } catch {
    return null;
  }
}
```

- [ ] **Step 2: Add getPendingPrompts()**

```javascript
function getPendingPrompts(repoPath) {
  if (!repoPath) return [];
  const filePath = path.join(repoPath, '.ai-workflow', 'context', 'PROMPT_TRACKER.log');
  try {
    const raw = fs.readFileSync(filePath, 'utf8').trim();
    if (!raw) return [];
    return raw.split('\n').map(line => {
      const parts = line.split('|');
      return {
        id: parts[0], status: parts[1], timestamp: parts[2], description: parts[3],
        type: parts[4] || 'CRAFTED', parentId: parts[5] || null,
        files: parts[6] ? parts[6].split(',').filter(Boolean) : [],
      };
    }).filter(p => p.status !== 'DONE' && p.status !== 'FAILED');
  } catch {
    return [];
  }
}
```

- [ ] **Step 3: Add readRelayMode()**

```javascript
function readRelayMode(repoPath) {
  if (!repoPath) return 'review';
  const filePath = path.join(repoPath, '.ai-workflow', 'context', 'RELAY_MODE');
  try {
    return fs.readFileSync(filePath, 'utf8').trim() || 'review';
  } catch {
    return 'review';
  }
}
```

- [ ] **Step 4: Add assembleBundle()**

```javascript
function assembleBundle(repoPath, clip, project) {
  return {
    userIntent: clip.comment || '',
    aiInterpretation: clip.aiFixPrompt || null,
    project: { name: project.name, repoPath: project.repo_path, description: project.description },
    git: getGitState(repoPath),
    session: readSessionContext(repoPath),
    auditFindings: readAuditFindings(repoPath),
    pendingPrompts: getPendingPrompts(repoPath),
    relayMode: readRelayMode(repoPath),
  };
}
```

- [ ] **Step 5: Update exports**

```javascript
module.exports = {
  readSessionContext, readAuditFindings, hasWorkflow,
  getGitState, getPendingPrompts, readRelayMode, assembleBundle,
};
```

- [ ] **Step 6: Commit**

```bash
git add src/workflow-context.js
git commit -m "feat(workflow-context): add git state, prompt parsing, relay mode, bundle assembly"
```

---

## Task 3: Prompt ID Generation + PROMPT_TRACKER Writing

**Files:**
- Modify: `src/main.js` (add generatePromptId function and tracker append logic)

- [ ] **Step 1: Add prompt ID generator**

In main.js, after the imports section:

```javascript
// ── Prompt ID Generation ──
let batchLetter = 0; // 0=a, 1=b, etc. Resets on restart.

function generatePromptId(scope) {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, '0');
  const mm = String(now.getMinutes()).padStart(2, '0');
  const MM = String(now.getMonth() + 1).padStart(2, '0');
  const DD = String(now.getDate()).padStart(2, '0');
  const letter = String.fromCharCode(97 + batchLetter); // a, b, c...
  batchLetter++;
  return `${scope}:${hh}${mm}:${MM}${DD}:${letter}`;
}

function appendToPromptTracker(repoPath, id, description, type = 'CRAFTED') {
  const trackerPath = path.join(repoPath, '.ai-workflow', 'context', 'PROMPT_TRACKER.log');
  const timestamp = new Date().toISOString();
  const line = `${id}|BUNDLED|${timestamp}|${description}|${type}|\n`;
  fs.appendFileSync(trackerPath, line, 'utf8');
}

function deriveScope(clip, project) {
  // Try category → component label mapping
  if (clip.category && clip.category !== 'Uncategorized') {
    return clip.category.toLowerCase().replace(/[^a-z0-9]/g, '-').substring(0, 20);
  }
  // Fallback: slugify project name
  if (project?.name) {
    return project.name.toLowerCase().replace(/[^a-z0-9]/g, '-').substring(0, 20);
  }
  return 'general';
}
```

- [ ] **Step 2: Commit**

```bash
git add src/main.js
git commit -m "feat(main): add prompt ID generation and PROMPT_TRACKER append logic"
```

---

## Task 4: Bundle & Send IPC Handler

**Files:**
- Modify: `src/main.js` (new IPC handlers)
- Modify: `src/preload.js` (expose new methods)

- [ ] **Step 1: Add formatBundle helper in main.js**

```javascript
function formatBundle(promptId, clip, bundle, annotationColors) {
  let md = `# HuminLoop Dev Prompt\n## Prompt ID: ${promptId}\n\n`;
  md += `## User Intent\n${bundle.userIntent || '(no note)'}\n\n`;
  if (bundle.aiInterpretation) {
    md += `## AI Interpretation\n${bundle.aiInterpretation}\n\n`;
  }
  md += `## Screenshot\nAttached separately as ide-prompt-image-${promptId}.png\n\n`;

  // Annotation guide from custom colors
  md += `## Annotation Guide\n`;
  if (annotationColors && annotationColors.length) {
    annotationColors.forEach(c => {
      md += `- ${c.id} (${c.hex}) — ${c.label}\n`;
    });
  } else {
    md += `- Red (#FF0000) — Delete / Remove / Error\n`;
    md += `- Green (#00FF00) — Add / Insert\n`;
    md += `- Pink (#FF69B4) — Identify / Reference / Question\n`;
  }
  md += `\n`;

  // Project context
  if (bundle.git) {
    md += `## Project Context\n`;
    md += `- Project: ${bundle.project.name}\n`;
    md += `- Branch: ${bundle.git.branch}\n`;
    md += `- Last commits:\n`;
    bundle.git.lastCommits.forEach(c => {
      md += `  - ${c.hash} ${c.message}\n`;
    });
    md += `\n`;

    if (bundle.git.dirtyFiles.length > 0) {
      md += `## Dirty Files\n`;
      bundle.git.dirtyFiles.forEach(f => {
        md += `- ${f.file} (${f.status})\n`;
      });
      md += `\n`;
    }
  }

  if (bundle.session) {
    md += `## Session State\n${bundle.session}\n\n`;
  }

  if (bundle.pendingPrompts.length > 0) {
    md += `## Pending Work\n`;
    bundle.pendingPrompts.forEach(p => {
      md += `- ${p.id}: ${p.description} [${p.status}]\n`;
    });
    md += `\n`;
  }

  if (bundle.auditFindings) {
    // Just the last entry (after the last ## heading)
    const sections = bundle.auditFindings.split(/^## /m);
    const lastSection = sections[sections.length - 1];
    if (lastSection?.trim()) {
      md += `## Recent Audit Findings\n## ${lastSection.trim()}\n`;
    }
  }

  return md;
}
```

- [ ] **Step 2: Add bundle-and-send IPC handler**

```javascript
ipcMain.handle('bundle-and-send', async (_, clipId, scopeOverride) => {
  const clip = await db.getClip(clipId);
  if (!clip) throw new Error('Clip not found');
  if (!clip.project_id) throw new Error('Clip not assigned to a project');
  const project = await db.getProject(clip.project_id);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const scope = scopeOverride || deriveScope(clip, project);
  const promptId = generatePromptId(scope);
  const bundle = workflowContext.assembleBundle(project.repo_path, clip, project);
  const annotationColors = await db.getSettings('annotation_colors');
  const markdown = formatBundle(promptId, clip, bundle, annotationColors);

  // Write prompt file (named with ID to support queuing)
  const contextDir = path.join(project.repo_path, '.ai-workflow', 'context');
  if (!fs.existsSync(contextDir)) fs.mkdirSync(contextDir, { recursive: true });

  const safeId = promptId.replace(/:/g, '-');
  fs.writeFileSync(path.join(contextDir, `IDE_PROMPT_${safeId}.md`), markdown, 'utf8');

  // Write image if available
  const dataUrl = images.loadImage(clipId);
  if (dataUrl) {
    const base64 = dataUrl.replace(/^data:image\/\w+;base64,/, '');
    fs.writeFileSync(path.join(contextDir, `ide-prompt-image-${safeId}.png`), Buffer.from(base64, 'base64'));
  }

  // Log to prompt tracker
  const desc = (clip.comment || '(screenshot)').slice(0, 80);
  appendToPromptTracker(project.repo_path, promptId, desc, 'CRAFTED');

  // Update clip
  await db.updateClip(clipId, { sent_to_ide_at: new Date().toISOString(), prompt_id: promptId });

  addAuditEntry('bundle-send', `Clip ${clipId} bundled as ${promptId} for IDE at ${project.repo_path}`);
  notifyMainWindow('clips-changed');
  notifyMainWindow('clip-sent-to-ide', { clipId, promptId, projectName: project.name });
  return { success: true, promptId, path: project.repo_path };
});
```

- [ ] **Step 3: Add bundle-and-send-multiple IPC handler**

```javascript
ipcMain.handle('bundle-and-send-multiple', async (_, clipIds, projectId, scopeOverride) => {
  if (!Array.isArray(clipIds) || clipIds.length === 0) throw new Error('No clips provided');
  if (!projectId) throw new Error('project_id required');
  const project = await db.getProject(projectId);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const allClips = await db.getClips();
  const selected = allClips.filter(c => clipIds.includes(c.id));
  if (selected.length === 0) throw new Error('No matching clips');

  // Use first clip for scope derivation
  const scope = scopeOverride || deriveScope(selected[0], project);
  const promptId = generatePromptId(scope);

  // Combine user intents
  const combinedComment = selected.map(c => c.comment || '(screenshot)').join('\n---\n');
  const combinedClip = { ...selected[0], comment: combinedComment, aiFixPrompt: null };

  // Generate combined AI prompt if available
  if (ai.isEnabled()) {
    const notes = selected.map(c => {
      const raw = images.loadImage(c.id);
      return { id: c.id, comment: c.comment || '', imageDataURL: raw ? images.compressForAI(raw) : null };
    });
    const combinedPrompt = await ai.generateCombinedPrompt(notes);
    combinedClip.aiFixPrompt = combinedPrompt;
  }

  const bundle = workflowContext.assembleBundle(project.repo_path, combinedClip, project);
  const annotationColors = await db.getSettings('annotation_colors');
  const markdown = formatBundle(promptId, combinedClip, bundle, annotationColors);

  const contextDir = path.join(project.repo_path, '.ai-workflow', 'context');
  if (!fs.existsSync(contextDir)) fs.mkdirSync(contextDir, { recursive: true });

  const safeId = promptId.replace(/:/g, '-');
  fs.writeFileSync(path.join(contextDir, `IDE_PROMPT_${safeId}.md`), markdown, 'utf8');

  // Write first clip's image as representative
  const dataUrl = images.loadImage(selected[0].id);
  if (dataUrl) {
    const base64 = dataUrl.replace(/^data:image\/\w+;base64,/, '');
    fs.writeFileSync(path.join(contextDir, `ide-prompt-image-${safeId}.png`), Buffer.from(base64, 'base64'));
  }

  const desc = `Combined ${selected.length} clips: ${combinedComment.slice(0, 60)}`;
  appendToPromptTracker(project.repo_path, promptId, desc, 'CRAFTED');

  const sentAt = new Date().toISOString();
  for (const c of selected) {
    await db.updateClip(c.id, { sent_to_ide_at: sentAt, prompt_id: promptId });
  }

  addAuditEntry('bundle-send', `${selected.length} clips bundled as ${promptId} for IDE at ${project.repo_path}`);
  notifyMainWindow('clips-changed');
  notifyMainWindow('clip-sent-to-ide', { clipIds, promptId, projectName: project.name });
  return { success: true, promptId, path: project.repo_path };
});
```

- [ ] **Step 4: Add preload methods**

In `src/preload.js`, add to the `quickclip` object:

```javascript
// Dev workflow
bundleAndSend: (clipId, scope) => ipcRenderer.invoke('bundle-and-send', clipId, scope),
bundleAndSendMultiple: (clipIds, projectId, scope) => ipcRenderer.invoke('bundle-and-send-multiple', clipIds, projectId, scope),
```

- [ ] **Step 5: Test and commit**

Launch app, verify bundle-and-send writes `IDE_PROMPT_*.md` to the project's `.ai-workflow/context/`.

```bash
git add src/main.js src/preload.js
git commit -m "feat(main): add bundle-and-send IPC handlers with context bundling"
```

---

## Task 5: Prompt Status Update API Endpoint

**Files:**
- Modify: `src/api-server.js`
- Modify: `src/main.js` (add IPC handler for status update)
- Modify: `src/preload.js` (expose method)

- [ ] **Step 1: Add PATCH /api/workflow/prompts/:id to api-server.js**

In api-server.js, before the `// ── 404 ──` line, inside the workflow section:

```javascript
// PATCH /api/workflow/prompts/:id — update prompt status
if (method === 'PATCH' && (m = matchRoute('/api/workflow/prompts/:id', pathname))) {
  const body = await parseBody(req);
  const newStatus = body.status;
  if (!newStatus) return error(res, 'status required');

  const validStatuses = ['CRAFTED', 'BUNDLED', 'SENT', 'BUILDING', 'DONE', 'FAILED'];
  if (!validStatuses.includes(newStatus)) return error(res, `Invalid status. Must be one of: ${validStatuses.join(', ')}`);

  const promptId = decodeURIComponent(m.params.id);

  // Find the project with this prompt — scan all projects for PROMPT_TRACKER.log
  const projects = await db.getProjects();
  let updated = false;
  for (const p of projects) {
    if (!p.repo_path) continue;
    const trackerPath = path.join(p.repo_path, '.ai-workflow', 'context', 'PROMPT_TRACKER.log');
    try {
      const raw = fs.readFileSync(trackerPath, 'utf8');
      if (!raw.includes(promptId)) continue;

      const lines = raw.split('\n');
      const newLines = lines.map(line => {
        if (line.startsWith(promptId + '|')) {
          const parts = line.split('|');
          parts[1] = newStatus;
          // Append affected files if provided (7th field)
          if (body.files) {
            // Ensure we have enough fields (pad with empty if needed)
            while (parts.length < 7) parts.push('');
            parts[6] = typeof body.files === 'string' ? body.files : body.files.join(',');
          }
          return parts.join('|');
        }
        return line;
      });
      fs.writeFileSync(trackerPath, newLines.join('\n'), 'utf8');
      updated = true;
      break;
    } catch {}
  }

  if (!updated) return error(res, 'Prompt not found in any project tracker', 404);
  return json(res, { success: true, id: promptId, status: newStatus });
}
```

- [ ] **Step 2: Commit**

```bash
git add src/api-server.js
git commit -m "feat(api): add PATCH /api/workflow/prompts/:id for prompt status updates"
```

---

## Task 6: Update MCP get_pending_prompt for FIFO Queue

**Files:**
- Modify: `mcp-server/index.js`

- [ ] **Step 1: Update get_pending_prompt to scan for IDE_PROMPT_*.md files**

Replace the existing `get_pending_prompt` handler:

```javascript
async get_pending_prompt() {
  const ctxDir = path.join(PROJECT_ROOT, '.ai-workflow', 'context');

  // Scan for queued prompt files (FIFO — oldest first by filename)
  let promptFiles = [];
  try {
    const files = fs.readdirSync(ctxDir);
    promptFiles = files
      .filter(f => f.startsWith('IDE_PROMPT_') && f.endsWith('.md'))
      .sort(); // alphabetical = chronological due to timestamp in name
  } catch {
    return textResult('No pending IDE prompt found. Use HuminLoop to send a prompt to IDE first.');
  }

  // Also check legacy single file
  const legacyPath = path.join(ctxDir, 'IDE_PROMPT.md');
  const hasLegacy = fs.existsSync(legacyPath);

  if (promptFiles.length === 0 && !hasLegacy) {
    return textResult('No pending IDE prompt found. Use HuminLoop to send a prompt to IDE first.');
  }

  let promptPath, imagePath, promptId;

  if (promptFiles.length > 0) {
    // Use oldest queued file
    const fileName = promptFiles[0];
    promptPath = path.join(ctxDir, fileName);
    // Extract ID from filename: IDE_PROMPT_{safeId}.md → safeId → restore colons
    const safeId = fileName.replace('IDE_PROMPT_', '').replace('.md', '');
    promptId = safeId; // Keep safe ID for image matching
    imagePath = path.join(ctxDir, `ide-prompt-image-${safeId}.png`);
  } else {
    // Legacy single file
    promptPath = legacyPath;
    imagePath = path.join(ctxDir, 'ide-prompt-image.png');
    promptId = null;
  }

  let promptText;
  try {
    promptText = fs.readFileSync(promptPath, 'utf-8');
  } catch {
    return textResult('No pending IDE prompt found.');
  }

  const content = [{ type: 'text', text: promptText }];

  // Include image if it exists
  try {
    const imgBuf = fs.readFileSync(imagePath);
    content.push(imageContent(imgBuf.toString('base64'), 'image/png'));
  } catch {}

  // Clean up (one-shot delivery)
  try { fs.unlinkSync(promptPath); } catch {}
  try { fs.unlinkSync(imagePath); } catch {}

  // Update prompt status to SENT via API
  if (promptId) {
    // Extract the real prompt ID from the markdown content
    const idMatch = promptText.match(/^## Prompt ID: (.+)$/m);
    if (idMatch) {
      try {
        await api('PATCH', `/api/workflow/prompts/${encodeURIComponent(idMatch[1])}`, { status: 'SENT' });
      } catch (e) {
        // Non-fatal — prompt was delivered even if status update fails
        console.error('[MCP] Failed to update prompt status:', e.message);
      }
    }
  }

  return { content };
},
```

- [ ] **Step 2: Test and commit**

Verify: Create a bundled prompt via HuminLoop, then call `get_pending_prompt` from MCP — file should be consumed and status updated to SENT.

```bash
git add mcp-server/index.js
git commit -m "feat(mcp): update get_pending_prompt for FIFO queue and status tracking"
```

---

## Task 7: Annotation Color Customization

**Files:**
- Modify: `src/ai.js` (dynamic color prompt)
- Modify: `src/main.js` (IPC handlers for annotation colors)
- Modify: `src/preload.js` (expose methods)
- Modify: `renderer/index.js` (settings UI)

- [ ] **Step 1: Make FOCUSED_PROMPT dynamic in ai.js**

Replace the hardcoded `FOCUSED_PROMPT` constant with a function:

```javascript
const DEFAULT_ANNOTATION_COLORS = [
  { id: 'red', hex: '#FF0000', label: 'Remove, delete, or fix what is marked', shortLabel: 'remove' },
  { id: 'green', hex: '#00FF00', label: 'Add or create something at this location', shortLabel: 'add' },
  { id: 'pink', hex: '#FF69B4', label: 'Reference point — identifying or pointing out this element for context', shortLabel: 'reference' },
];

function buildFocusedPrompt(annotationColors) {
  const colors = annotationColors && annotationColors.length > 0 ? annotationColors : DEFAULT_ANNOTATION_COLORS;
  const colorLines = colors.map(c =>
    `- ${c.id.toUpperCase()} markings (${c.hex}): ${c.label}`
  ).join('\n');

  return `You are analyzing a screenshot with colored annotations from a developer.
The annotations follow this color coding:
${colorLines}

PRIORITY: The developer's written note is the primary source of intent. If the note clarifies, overrides, or adds nuance to what the color annotations suggest, follow the note. Annotations are also expressions of intent and should be treated as instructions — but when the note and annotations conflict, the note wins.

Use the project context and session information to generate a more specific and relevant prompt. Reference the current branch, recent work, and known issues where they relate to what the annotations and note describe.

Generate a single, specific, actionable prompt that a coding AI could execute directly. Be concrete about what to change based on the annotations and note. Reference marked elements as context when relevant. Output only the prompt text, no explanation or formatting.`;
}
```

- [ ] **Step 2: Update generateFocusedPrompt to accept colors**

Update the function signature and body:

```javascript
async function generateFocusedPrompt(comment, imageDataURL, windowMeta = {}, project = {}, workflowContext = {}, annotationColors = null) {
  if (!isEnabled()) return null;
  // ... existing parts building unchanged ...
  try {
    const systemPrompt = buildFocusedPrompt(annotationColors);
    const result = await callGemini(systemPrompt, messageParts, { raw: true });
    if (!result) return null;
    return result.replace(/^["'`]+|["'`]+$/g, '').trim();
  } catch (e) {
    console.error('[HuminLoop AI] Focused prompt generation failed:', e.message);
    return null;
  }
}
```

- [ ] **Step 3: Update autoCategorizeFocused in main.js to pass colors**

```javascript
async function autoCategorizeFocused(clipId, comment, imageData, windowTitle, processName) {
  try {
    const projectId = await db.getSettings('focused_active_project');
    const project = projectId ? await db.getProject(projectId) : {};
    const session = project.repo_path ? workflowContext.readSessionContext(project.repo_path) : null;
    const audit = project.repo_path ? workflowContext.readAuditFindings(project.repo_path) : null;
    const annotationColors = await db.getSettings('annotation_colors');
    const compressedImage = imageData ? images.compressForAI(imageData) : null;
    const prompt = await ai.generateFocusedPrompt(
      comment, compressedImage,
      { windowTitle, processName },
      { name: project.name, description: project.description, repo_path: project.repo_path },
      { session, audit },
      annotationColors
    );
    // ... rest unchanged (save to DB, auto-copy, etc.) ...
  } catch (e) {
    console.error('[HuminLoop] Focused prompt generation failed:', e.message);
  }
}
```

- [ ] **Step 4: Add annotation color IPC handlers in main.js**

```javascript
ipcMain.handle('get-annotation-colors', async () => {
  const colors = await db.getSettings('annotation_colors');
  return colors || null; // null means use defaults
});

ipcMain.handle('save-annotation-colors', async (_, colors) => {
  await db.saveSetting('annotation_colors', colors);
  return true;
});
```

- [ ] **Step 5: Add preload methods**

```javascript
getAnnotationColors: () => ipcRenderer.invoke('get-annotation-colors'),
saveAnnotationColors: (colors) => ipcRenderer.invoke('save-annotation-colors', colors),
```

- [ ] **Step 6: Add annotation color settings UI in renderer/index.js**

In the Settings tab rendering function, add a new section. Find where other settings sections are rendered and add:

```javascript
function renderAnnotationColorSettings() {
  const colors = settings.annotation_colors || [
    { id: 'red', hex: '#FF0000', label: 'Delete / Remove / Error', shortLabel: 'remove' },
    { id: 'green', hex: '#00FF00', label: 'Add / Insert', shortLabel: 'add' },
    { id: 'pink', hex: '#FF69B4', label: 'Identify / Reference / Question', shortLabel: 'reference' },
  ];

  let html = '<div class="settings-section"><h3>Annotation Colors</h3>';
  html += '<p class="settings-hint">Define colors used in screenshot annotations. These labels are used by AI when interpreting your markings.</p>';
  html += '<div id="annotation-colors-list">';

  colors.forEach((c, i) => {
    html += `<div class="annotation-color-row" data-index="${i}">`;
    html += `<input type="color" value="${escAttr(c.hex)}" onchange="updateAnnotationColor(${i}, 'hex', this.value)" />`;
    html += `<input type="text" value="${escAttr(c.id)}" placeholder="ID (e.g. red)" class="color-id-input" onchange="updateAnnotationColor(${i}, 'id', this.value)" />`;
    html += `<input type="text" value="${escAttr(c.label)}" placeholder="Label" class="color-label-input" onchange="updateAnnotationColor(${i}, 'label', this.value)" />`;
    html += `<input type="text" value="${escAttr(c.shortLabel)}" placeholder="Short" class="color-short-input" onchange="updateAnnotationColor(${i}, 'shortLabel', this.value)" />`;
    if (i > 0) html += `<button class="color-move-btn" onclick="moveAnnotationColor(${i}, -1)" title="Move up">&uarr;</button>`;
    if (i < colors.length - 1) html += `<button class="color-move-btn" onclick="moveAnnotationColor(${i}, 1)" title="Move down">&darr;</button>`;
    html += `<button class="del-btn" onclick="removeAnnotationColor(${i})" title="Remove">&times;</button>`;
    html += `</div>`;
  });

  html += '</div>';
  html += '<button class="btn-secondary" onclick="addAnnotationColor()">+ Add Color</button>';
  html += '</div>';
  return html;
}
```

- [ ] **Step 7: Add annotation color JS handlers in renderer/index.js**

```javascript
async function updateAnnotationColor(index, field, value) {
  const colors = settings.annotation_colors || [
    { id: 'red', hex: '#FF0000', label: 'Delete / Remove / Error', shortLabel: 'remove' },
    { id: 'green', hex: '#00FF00', label: 'Add / Insert', shortLabel: 'add' },
    { id: 'pink', hex: '#FF69B4', label: 'Identify / Reference / Question', shortLabel: 'reference' },
  ];
  colors[index][field] = value;
  await window.quickclip.saveAnnotationColors(colors);
  settings.annotation_colors = colors;
}

async function addAnnotationColor() {
  const colors = settings.annotation_colors || [
    { id: 'red', hex: '#FF0000', label: 'Delete / Remove / Error', shortLabel: 'remove' },
    { id: 'green', hex: '#00FF00', label: 'Add / Insert', shortLabel: 'add' },
    { id: 'pink', hex: '#FF69B4', label: 'Identify / Reference / Question', shortLabel: 'reference' },
  ];
  colors.push({ id: 'new', hex: '#808080', label: 'New color', shortLabel: 'new' });
  await window.quickclip.saveAnnotationColors(colors);
  settings.annotation_colors = colors;
  renderAll();
}

async function removeAnnotationColor(index) {
  const colors = settings.annotation_colors || [];
  colors.splice(index, 1);
  await window.quickclip.saveAnnotationColors(colors);
  settings.annotation_colors = colors;
  renderAll();
}

async function moveAnnotationColor(index, direction) {
  const colors = settings.annotation_colors || [];
  const newIndex = index + direction;
  if (newIndex < 0 || newIndex >= colors.length) return;
  [colors[index], colors[newIndex]] = [colors[newIndex], colors[index]];
  await window.quickclip.saveAnnotationColors(colors);
  settings.annotation_colors = colors;
  renderAll();
}
```

- [ ] **Step 8: Commit**

```bash
git add src/ai.js src/main.js src/preload.js renderer/index.js
git commit -m "feat: add annotation color customization with dynamic AI prompt generation"
```

---

## Task 8: Workflow Scaffolding — Bundled Templates + Init

**Files:**
- Create: `workflow-templates/instructions/SHARED.md`
- Create: `workflow-templates/instructions/ARCHITECT.md`
- Create: `workflow-templates/instructions/BUILDER.md`
- Create: `workflow-templates/instructions/REVIEWER.md`
- Create: `workflow-templates/instructions/SCREENER.md`
- Create: `workflow-templates/scripts/prompt-tracker.sh`
- Create: `workflow-templates/scripts/ensure-workflow.sh`
- Create: `workflow-templates/scripts/show-status.sh`
- Create: `workflow-templates/scripts/compose-instructions.sh`
- Create: `workflow-templates/scripts/toggle-relay-mode.sh`
- Create: `workflow-templates/scripts/toggle-audit-watch.sh`
- Create: `workflow-templates/hooks/prepare-commit-msg`
- Modify: `src/workflow-context.js` (add scaffoldWorkflow)
- Modify: `src/main.js` (add init-dev-workflow IPC handler)
- Modify: `src/preload.js` (expose initDevWorkflow)

- [ ] **Step 1: Create workflow-templates directory**

```bash
mkdir -p workflow-templates/instructions workflow-templates/scripts workflow-templates/hooks
```

- [ ] **Step 2: Copy existing .ai-workflow files as templates**

Copy each file from `.ai-workflow/` into `workflow-templates/`, replacing project-specific values with `{{placeholders}}`:
- `{{PROJECT_NAME}}` — project name
- `{{REPO_PATH}}` — absolute repo path
- `{{TIMESTAMP}}` — ISO timestamp at scaffold time
- `{{BRANCH}}` — current git branch

For the instruction files (`SHARED.md`, `ARCHITECT.md`, `BUILDER.md`, `REVIEWER.md`, `SCREENER.md`): copy as-is from `.ai-workflow/instructions/` since they are already generic. Remove any QuickClip-specific references and replace with `{{PROJECT_NAME}}`.

For scripts: copy as-is from `.ai-workflow/scripts/` — they are already generic.

For the git hook: create a new template at `workflow-templates/hooks/prepare-commit-msg` that includes both the existing builder summary logic AND the new Prompt ID parsing + API call (from spec Section 10).

- [ ] **Step 3: Add scaffoldWorkflow to workflow-context.js**

```javascript
function scaffoldWorkflow(repoPath, projectName, apiPort = 7277) {
  const workflowDir = path.join(repoPath, '.ai-workflow');
  if (fs.existsSync(workflowDir)) {
    return { success: false, reason: 'already_exists' };
  }

  const templateDir = getTemplateDir();

  // Create directory structure
  const dirs = ['instructions', 'context', 'scripts', 'config'];
  dirs.forEach(d => fs.mkdirSync(path.join(workflowDir, d), { recursive: true }));

  // Copy and substitute instruction templates
  const instructionFiles = ['SHARED.md', 'ARCHITECT.md', 'BUILDER.md', 'REVIEWER.md', 'SCREENER.md'];
  instructionFiles.forEach(f => {
    const src = path.join(templateDir, 'instructions', f);
    if (fs.existsSync(src)) {
      let content = fs.readFileSync(src, 'utf8');
      content = content.replace(/\{\{PROJECT_NAME\}\}/g, projectName);
      content = content.replace(/\{\{REPO_PATH\}\}/g, repoPath);
      fs.writeFileSync(path.join(workflowDir, 'instructions', f), content, 'utf8');
    }
  });

  // Copy scripts
  const scriptsDir = path.join(templateDir, 'scripts');
  if (fs.existsSync(scriptsDir)) {
    fs.readdirSync(scriptsDir).forEach(f => {
      fs.copyFileSync(path.join(scriptsDir, f), path.join(workflowDir, 'scripts', f));
    });
  }

  // Initialize context files
  const now = new Date().toISOString();
  let branch = 'main';
  try {
    branch = require('child_process').execSync('git rev-parse --abbrev-ref HEAD', { cwd: repoPath, encoding: 'utf8' }).trim();
  } catch {}

  fs.writeFileSync(path.join(workflowDir, 'context', 'SESSION.md'),
    `# Session Context\n\n- Branch: ${branch}\n- Initialized: ${now}\n- Project: ${projectName}\n`, 'utf8');
  fs.writeFileSync(path.join(workflowDir, 'context', 'PROMPT_TRACKER.log'), '', 'utf8');
  fs.writeFileSync(path.join(workflowDir, 'context', 'RELAY_MODE'), 'review', 'utf8');
  fs.writeFileSync(path.join(workflowDir, 'context', 'AUDIT_WATCH_MODE'), 'off', 'utf8');
  fs.writeFileSync(path.join(workflowDir, 'context', 'CHANGELOG.md'), `# Changelog\n\nInitialized ${now}\n`, 'utf8');
  fs.writeFileSync(path.join(workflowDir, 'context', 'AUDIT_LOG.md'), `# Audit Log\n`, 'utf8');

  // Write API port config
  fs.writeFileSync(path.join(workflowDir, 'config', 'api-port'), String(apiPort), 'utf8');

  // Install git hook
  installGitHook(repoPath, templateDir);

  return { success: true };
}

function getTemplateDir() {
  // Packaged app: resources/workflow-templates/
  // Dev mode: {project_root}/workflow-templates/
  const appDir = path.join(__dirname, '..');
  const devPath = path.join(appDir, 'workflow-templates');
  if (fs.existsSync(devPath)) return devPath;
  // Packaged — check resources
  const resourcesPath = path.join(process.resourcesPath || appDir, 'workflow-templates');
  if (fs.existsSync(resourcesPath)) return resourcesPath;
  return devPath; // fallback
}

function installGitHook(repoPath, templateDir) {
  const hooksDir = path.join(repoPath, '.git', 'hooks');
  if (!fs.existsSync(hooksDir)) return; // not a git repo

  const hookPath = path.join(hooksDir, 'prepare-commit-msg');
  const templateHook = path.join(templateDir, 'hooks', 'prepare-commit-msg');
  if (!fs.existsSync(templateHook)) return;

  const hookContent = fs.readFileSync(templateHook, 'utf8');
  const marker = '# --- HuminLoop Dev Workflow ---';

  if (fs.existsSync(hookPath)) {
    const existing = fs.readFileSync(hookPath, 'utf8');
    if (existing.includes(marker)) return; // already installed
    // Append to existing hook
    fs.appendFileSync(hookPath, `\n\n${marker}\n${hookContent}\n`, 'utf8');
  } else {
    fs.writeFileSync(hookPath, `#!/bin/bash\n\n${marker}\n${hookContent}\n`, 'utf8');
  }

  // Make executable (no-op on Windows, needed on Linux/Mac)
  try { fs.chmodSync(hookPath, '755'); } catch {}
}
```

- [ ] **Step 4: Update workflow-context.js exports**

Add `scaffoldWorkflow` to module.exports.

- [ ] **Step 5: Add init-dev-workflow IPC handler in main.js**

```javascript
ipcMain.handle('init-dev-workflow', async (_, projectId) => {
  const project = await db.getProject(projectId);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const apiPort = parseInt(process.env.HUMINLOOP_API_PORT || '7277', 10);
  const result = workflowContext.scaffoldWorkflow(project.repo_path, project.name, apiPort);

  if (result.success) {
    addAuditEntry('workflow-init', `Dev workflow initialized for ${project.name} at ${project.repo_path}`);
    notifyMainWindow('projects-changed');
  }
  return result;
});
```

- [ ] **Step 6: Add preload method**

```javascript
initDevWorkflow: (projectId) => ipcRenderer.invoke('init-dev-workflow', projectId),
```

- [ ] **Step 7: Commit**

```bash
git add workflow-templates/ src/workflow-context.js src/main.js src/preload.js
git commit -m "feat: add workflow scaffolding — bundled templates and init-dev-workflow handler"
```

---

## Task 9: IDE Auto-Detection & Setup (VS Code + Claude Code)

**Files:**
- Modify: `src/main.js` (IDE detection IPC handlers)
- Modify: `src/preload.js` (expose methods)

- [ ] **Step 1: Add IDE detection handlers in main.js**

```javascript
ipcMain.handle('detect-ide', async (_, repoPath) => {
  const result = { vsCodeInstalled: false, claudeCodeExtension: false, mcpConfigured: false };

  // Check VS Code CLI
  try {
    execSync('code --version', { encoding: 'utf8', timeout: 5000 });
    result.vsCodeInstalled = true;
  } catch {}

  // Check Claude Code extension
  const home = process.env.USERPROFILE || process.env.HOME || '';
  const extDir = path.join(home, '.vscode', 'extensions');
  try {
    const dirs = fs.readdirSync(extDir);
    result.claudeCodeExtension = dirs.some(d => d.startsWith('anthropic.claude-code'));
  } catch {}

  // Check MCP config
  if (repoPath) {
    const mcpPath = path.join(repoPath, '.vscode', 'mcp.json');
    try {
      const config = JSON.parse(fs.readFileSync(mcpPath, 'utf8'));
      result.mcpConfigured = !!(config.servers?.huminloop || config.mcpServers?.huminloop);
    } catch {}
  }

  return result;
});

ipcMain.handle('generate-mcp-config', async (_, projectId) => {
  const project = await db.getProject(projectId);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const mcpServerPath = path.join(__dirname, '..', 'mcp-server', 'index.js').replace(/\\/g, '/');
  const apiPort = process.env.HUMINLOOP_API_PORT || '7277';

  return {
    servers: {
      huminloop: {
        command: 'node',
        args: [mcpServerPath],
        env: {
          HUMINLOOP_API_PORT: apiPort,
          PROJECT_ROOT: project.repo_path.replace(/\\/g, '/'),
        },
      },
    },
  };
});

ipcMain.handle('write-mcp-config', async (_, projectId) => {
  const project = await db.getProject(projectId);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const config = await ipcMain.emit('generate-mcp-config'); // reuse logic
  // Actually, just inline it:
  const mcpServerPath = path.join(__dirname, '..', 'mcp-server', 'index.js').replace(/\\/g, '/');
  const apiPort = process.env.HUMINLOOP_API_PORT || '7277';
  const mcpConfig = {
    servers: {
      huminloop: {
        command: 'node',
        args: [mcpServerPath],
        env: {
          HUMINLOOP_API_PORT: apiPort,
          PROJECT_ROOT: project.repo_path.replace(/\\/g, '/'),
        },
      },
    },
  };

  const vscodeDir = path.join(project.repo_path, '.vscode');
  if (!fs.existsSync(vscodeDir)) fs.mkdirSync(vscodeDir, { recursive: true });

  const mcpPath = path.join(vscodeDir, 'mcp.json');
  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(mcpPath, 'utf8')); } catch {}

  // Merge — don't overwrite other servers
  existing.servers = existing.servers || {};
  existing.servers.huminloop = mcpConfig.servers.huminloop;

  fs.writeFileSync(mcpPath, JSON.stringify(existing, null, 2), 'utf8');
  addAuditEntry('ide-setup', `MCP config written for ${project.name} at ${mcpPath}`);
  return { success: true, path: mcpPath };
});
```

- [ ] **Step 2: Add preload methods**

```javascript
detectIde: (repoPath) => ipcRenderer.invoke('detect-ide', repoPath),
generateMcpConfig: (projectId) => ipcRenderer.invoke('generate-mcp-config', projectId),
writeMcpConfig: (projectId) => ipcRenderer.invoke('write-mcp-config', projectId),
```

- [ ] **Step 3: Commit**

```bash
git add src/main.js src/preload.js
git commit -m "feat: add IDE auto-detection and MCP config generation for VS Code"
```

---

## Task 10: Renderer — Dev Mode Detection + Clip Card Enrichments

**Files:**
- Modify: `renderer/index.js`

This is the big renderer task. It wires up dev detection, enriches clip cards, and adds the sidebar IDE connection section.

- [ ] **Step 1: Add dev mode state variables**

At the top of `renderer/index.js`, near the existing state vars:

```javascript
let isDevMode = false; // true when focused + project has .ai-workflow/
let ideStatus = null;  // { vsCodeInstalled, claudeCodeExtension, mcpConfigured }
let devPrompts = [];   // workflow prompts for the active project
let devFilter = 'all'; // 'all' | 'pending' | 'done'
```

- [ ] **Step 2: Add dev mode detection in loadData**

After the existing `loadData` function's project selection logic, add:

```javascript
// Check dev mode — does active project have .ai-workflow/?
if (isFocusedMode && selectedProjectId) {
  const project = projects.find(p => p.id === selectedProjectId);
  if (project?.repo_path) {
    const status = await window.quickclip.getWorkflowStatus();
    // getWorkflowStatus reads from HuminLoop's own .ai-workflow — we need the project's
    // Use hasWorkflow check via a new preload method, or check via status
    isDevMode = status.hasWorkflow; // TODO: this checks HuminLoop's own dir, need project-specific
    if (isDevMode) {
      ideStatus = await window.quickclip.detectIde(project.repo_path);
      devPrompts = await window.quickclip.getWorkflowPrompts();
    }
  } else {
    isDevMode = false;
  }
}
```

Note: `getWorkflowStatus` currently reads from HuminLoop's own `.ai-workflow/`. For dev mode, we need it to check the ACTIVE PROJECT's repo. Add a new IPC handler `has-project-workflow` that checks `hasWorkflow(project.repo_path)`:

In main.js:
```javascript
ipcMain.handle('has-project-workflow', async (_, projectId) => {
  const project = await db.getProject(projectId);
  if (!project?.repo_path) return false;
  return workflowContext.hasWorkflow(project.repo_path);
});
```

In preload.js:
```javascript
hasProjectWorkflow: (projectId) => ipcRenderer.invoke('has-project-workflow', projectId),
```

Then in loadData:
```javascript
if (isFocusedMode && selectedProjectId) {
  isDevMode = await window.quickclip.hasProjectWorkflow(selectedProjectId);
  if (isDevMode) {
    const project = projects.find(p => p.id === selectedProjectId);
    ideStatus = await window.quickclip.detectIde(project?.repo_path);
    devPrompts = await window.quickclip.getWorkflowPrompts();
  }
} else {
  isDevMode = false;
}
```

- [ ] **Step 3: Update applyFocusedMode for dev label**

```javascript
function applyFocusedMode() {
  // ... existing tab hiding logic ...
  const h1 = document.querySelector('.header h1');
  if (h1) {
    const label = document.createElement('span');
    label.className = 'focused-mode-label';
    label.id = 'mode-label';
    label.textContent = 'Focused';
    h1.parentNode.insertBefore(label, h1.nextSibling);
  }
  activeTab = 'projects';
  // ... existing tab activation ...
}

// Call after loadData to update label
function updateModeLabel() {
  const label = document.getElementById('mode-label');
  if (label) {
    label.textContent = isDevMode ? 'Focused — Dev' : 'Focused';
  }
}
```

- [ ] **Step 4: Enrich renderClipCard for dev mode**

In `renderClipCard`, after the existing status badge, add dev status badge:

```javascript
// Dev workflow status badge (after existing badges)
if (isDevMode && c.prompt_id) {
  const prompt = devPrompts.find(p => p.id === c.prompt_id);
  const pStatus = prompt?.status || 'CAPTURED';
  const filesCount = prompt?.files?.length || 0;
  const badgeClass = {
    'CAPTURED': 'badge-captured',
    'BUNDLED': 'badge-bundled',
    'CRAFTED': 'badge-bundled',
    'SENT': 'badge-sent',
    'BUILDING': 'badge-sent',
    'DONE': 'badge-done',
    'FAILED': 'badge-failed',
  }[pStatus] || 'badge-captured';
  html += `<span class="badge ${badgeClass}" title="Prompt: ${esc(c.prompt_id)}">${esc(pStatus)}</span>`;
  html += `<span class="prompt-id-label" title="Prompt ID">${esc(c.prompt_id)}</span>`;
  if (pStatus === 'DONE' && filesCount > 0) {
    const fileList = prompt.files.map(f => esc(f)).join('\n');
    html += `<span class="files-badge" title="${fileList}">${filesCount} file${filesCount > 1 ? 's' : ''} changed</span>`;
  }
}
```

Replace the existing "Send to IDE" button logic for dev mode:

```javascript
if (c.aiFixPrompt) {
  html += `<button class="copy-prompt-btn" onclick="copyPrompt('${id}')" title="Copy AI fix prompt to clipboard">&#x1F4CB; Prompt</button>`;
  if (c.project_id) {
    if (isDevMode) {
      // Dev mode: Bundle & Send replaces Send to IDE
      if (c.sentToIdeAt) {
        html += `<button class="send-ide-btn sent" onclick="bundleAndSend('${id}')" title="Bundled ${timeAgo(new Date(c.sentToIdeAt).getTime())} — click to resend">&#x2705; Bundled</button>`;
      } else {
        html += `<button class="bundle-send-btn" onclick="bundleAndSend('${id}')" title="Bundle context and send to IDE">&#x1F4E6; Bundle &amp; Send</button>`;
      }
    } else {
      // Non-dev: existing Send to IDE behavior
      if (c.sentToIdeAt) {
        html += `<button class="send-ide-btn sent" onclick="sendClipToIde('${id}')" title="Sent to IDE ${timeAgo(new Date(c.sentToIdeAt).getTime())} — click to resend">&#x2705; Sent</button>`;
      } else {
        html += `<button class="send-ide-btn" onclick="sendClipToIde('${id}')" title="Send prompt to IDE AI chat">&#x1F4E4; IDE</button>`;
      }
    }
  }
}
```

- [ ] **Step 5: Add bundleAndSend JS function**

```javascript
async function bundleAndSend(clipId) {
  try {
    const result = await window.quickclip.bundleAndSend(clipId);
    if (result.success) {
      await loadData();
      renderAll();
    }
  } catch (e) {
    console.error('Bundle & Send failed:', e.message);
    alert('Bundle & Send failed: ' + e.message);
  }
}

async function bundleAndSendSelected() {
  if (selectedClipIds.size === 0) return;
  try {
    const result = await window.quickclip.bundleAndSendMultiple(
      [...selectedClipIds], selectedProjectId
    );
    if (result.success) {
      selectMode = false;
      selectedClipIds.clear();
      await loadData();
      renderAll();
    }
  } catch (e) {
    console.error('Bundle & Send failed:', e.message);
    alert('Bundle & Send failed: ' + e.message);
  }
}
```

- [ ] **Step 6: Commit**

```bash
git add renderer/index.js src/main.js src/preload.js
git commit -m "feat(renderer): add dev mode detection, clip status badges, and Bundle & Send"
```

---

## Task 11: Renderer — IDE Connection Sidebar + Scaffolding Button

**Files:**
- Modify: `renderer/index.js`

- [ ] **Step 1: Add IDE connection section to sidebar rendering**

Find the sidebar rendering for Focused mode (the project list sidebar). After the project info section, add:

```javascript
function renderIdeConnectionSection() {
  if (!isDevMode && !isFocusedMode) return '';
  const project = projects.find(p => p.id === selectedProjectId);
  if (!project?.repo_path) return '';

  let html = '<div class="sidebar-section ide-connection">';
  html += '<div class="sec">IDE Connection</div>';

  if (!isDevMode) {
    // No .ai-workflow — offer scaffolding
    html += `<p class="sidebar-hint">No dev workflow found in this project.</p>`;
    html += `<button class="btn-primary" onclick="initDevWorkflow(${project.id})">Set up Dev Workflow</button>`;
    html += '</div>';
    return html;
  }

  // Dev mode active — show IDE status
  if (!ideStatus) {
    html += '<p class="sidebar-hint">Checking IDE...</p>';
  } else if (!ideStatus.vsCodeInstalled) {
    html += '<p class="sidebar-hint">VS Code not found on this system.</p>';
  } else if (!ideStatus.claudeCodeExtension) {
    html += '<p class="sidebar-hint">VS Code found, but Claude Code extension not installed.</p>';
  } else if (!ideStatus.mcpConfigured) {
    html += '<p class="sidebar-hint">VS Code + Claude Code found.</p>';
    html += `<button class="btn-primary" onclick="showMcpSetup(${project.id})">Connect HuminLoop</button>`;
  } else {
    // Configured — show connection status
    const connected = project.active_in_ide;
    const dotClass = connected ? 'ide-dot-green' : 'ide-dot-gray';
    const label = connected ? 'Connected' : 'Configured — waiting for connection';
    html += `<div class="ide-status"><span class="ide-dot ${dotClass}"></span> ${label}</div>`;
  }

  // Pending prompt count
  const pendingCount = devPrompts.filter(p => p.status !== 'DONE' && p.status !== 'FAILED').length;
  if (pendingCount > 0) {
    html += `<div class="pending-badge">${pendingCount} prompt${pendingCount > 1 ? 's' : ''} pending</div>`;
  }

  html += '</div>';
  return html;
}
```

- [ ] **Step 2: Add initDevWorkflow and showMcpSetup JS functions**

```javascript
async function initDevWorkflow(projectId) {
  try {
    const result = await window.quickclip.initDevWorkflow(projectId);
    if (result.success) {
      await loadData();
      renderAll();
    } else if (result.reason === 'already_exists') {
      alert('Dev workflow already exists for this project.');
    }
  } catch (e) {
    alert('Failed to initialize dev workflow: ' + e.message);
  }
}

async function showMcpSetup(projectId) {
  try {
    const config = await window.quickclip.generateMcpConfig(projectId);
    const configJson = JSON.stringify(config, null, 2);

    // Show preview in a modal or inline panel
    const project = projects.find(p => p.id === projectId);
    const mcpPath = project.repo_path.replace(/\\/g, '/') + '/.vscode/mcp.json';

    const panel = document.getElementById('content');
    const overlay = document.createElement('div');
    overlay.className = 'mcp-setup-overlay';
    overlay.innerHTML = `
      <div class="mcp-setup-panel">
        <h3>Connect HuminLoop to VS Code</h3>
        <p>This will write the following config to <code>${esc(mcpPath)}</code>:</p>
        <pre class="mcp-config-preview">${esc(configJson)}</pre>
        <div class="mcp-setup-actions">
          <button class="btn-primary" onclick="applyMcpConfig(${projectId})">Apply</button>
          <button class="btn-secondary" onclick="copyMcpConfig()">Copy</button>
          <button class="btn-secondary" onclick="closeMcpSetup()">Cancel</button>
        </div>
      </div>
    `;
    overlay.id = 'mcp-setup-overlay';
    document.body.appendChild(overlay);

    // Store config for copy
    window._pendingMcpConfig = configJson;
  } catch (e) {
    alert('Failed to generate MCP config: ' + e.message);
  }
}

async function applyMcpConfig(projectId) {
  try {
    await window.quickclip.writeMcpConfig(projectId);
    closeMcpSetup();
    // Refresh IDE status
    const project = projects.find(p => p.id === projectId);
    ideStatus = await window.quickclip.detectIde(project?.repo_path);
    renderAll();
  } catch (e) {
    alert('Failed to write MCP config: ' + e.message);
  }
}

function copyMcpConfig() {
  if (window._pendingMcpConfig) {
    navigator.clipboard.writeText(window._pendingMcpConfig);
    const btn = document.querySelector('.mcp-setup-actions .btn-secondary');
    if (btn) { btn.textContent = 'Copied!'; setTimeout(() => btn.textContent = 'Copy', 2000); }
  }
}

function closeMcpSetup() {
  const overlay = document.getElementById('mcp-setup-overlay');
  if (overlay) overlay.remove();
  delete window._pendingMcpConfig;
}
```

- [ ] **Step 3: Wire sidebar section into render flow**

Find where the Focused mode sidebar is rendered and insert `renderIdeConnectionSection()` after the project list.

- [ ] **Step 4: Commit**

```bash
git add renderer/index.js
git commit -m "feat(renderer): add IDE connection sidebar and workflow scaffolding button"
```

---

## Task 12: Renderer — Dev Workflow Filters + Polling

**Files:**
- Modify: `renderer/index.js`

- [ ] **Step 1: Add dev filter controls**

In the clip list header area (where existing filter controls are), add dev-specific filters when `isDevMode`:

```javascript
function renderDevFilters() {
  if (!isDevMode) return '';
  return `
    <div class="dev-filter-bar">
      <button class="filter-btn${devFilter === 'all' ? ' active' : ''}" onclick="setDevFilter('all')">All</button>
      <button class="filter-btn${devFilter === 'pending' ? ' active' : ''}" onclick="setDevFilter('pending')">Pending</button>
      <button class="filter-btn${devFilter === 'done' ? ' active' : ''}" onclick="setDevFilter('done')">Done</button>
    </div>
  `;
}

function setDevFilter(filter) {
  devFilter = filter;
  renderAll();
}
```

- [ ] **Step 2: Apply dev filter to clip rendering**

In the clip list rendering, after existing filters, add:

```javascript
if (isDevMode && devFilter !== 'all') {
  filteredClips = filteredClips.filter(c => {
    const prompt = c.prompt_id ? devPrompts.find(p => p.id === c.prompt_id) : null;
    const status = prompt?.status || 'CAPTURED';
    if (devFilter === 'pending') return status !== 'DONE' && status !== 'FAILED';
    if (devFilter === 'done') return status === 'DONE';
    return true;
  });
}
```

- [ ] **Step 3: Add polling for dev mode**

```javascript
let devPollInterval = null;

function startDevPolling() {
  if (devPollInterval) return;
  devPollInterval = setInterval(async () => {
    if (!isDevMode || !isFocusedMode) return;
    const oldPrompts = JSON.stringify(devPrompts);
    devPrompts = await window.quickclip.getWorkflowPrompts();
    if (JSON.stringify(devPrompts) !== oldPrompts) {
      renderAll(); // Only re-render if something changed
    }
  }, 12000); // 12 seconds
}

function stopDevPolling() {
  if (devPollInterval) {
    clearInterval(devPollInterval);
    devPollInterval = null;
  }
}

// Refresh on window focus
window.addEventListener('focus', async () => {
  if (isDevMode && isFocusedMode) {
    const project = projects.find(p => p.id === selectedProjectId);
    isDevMode = await window.quickclip.hasProjectWorkflow(selectedProjectId);
    if (isDevMode) {
      ideStatus = await window.quickclip.detectIde(project?.repo_path);
      devPrompts = await window.quickclip.getWorkflowPrompts();
    }
    updateModeLabel();
    renderAll();
  }
});
```

Start polling when entering dev mode, stop when leaving:
- Call `startDevPolling()` after `isDevMode = true` in loadData
- Call `stopDevPolling()` when project changes or mode changes

- [ ] **Step 4: Commit**

```bash
git add renderer/index.js
git commit -m "feat(renderer): add dev workflow filters and polling for live status updates"
```

---

## Task 13: Git Hook Enhancement — Prompt ID Parsing

**Files:**
- Modify: `workflow-templates/hooks/prepare-commit-msg`
- Modify: `.git/hooks/prepare-commit-msg` (for this project specifically)

- [ ] **Step 1: Create the hook template**

Create `workflow-templates/hooks/prepare-commit-msg` with ONLY the Prompt ID parsing + API call logic (the builder summary logic stays in the existing hook — projects scaffold with both):

```bash
# --- HuminLoop Dev Workflow: Prompt ID Tracking ---
# Scans commit message for "# Prompt ID: xxx" and updates status to DONE

COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="$2"

# Skip merge, squash, amend
if [[ "$COMMIT_SOURCE" == "merge" || "$COMMIT_SOURCE" == "squash" || "$COMMIT_SOURCE" == "commit" ]]; then
    exit 0
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Extract Prompt ID from commit message
PROMPT_ID=$(grep -oP '(?<=^# Prompt ID: ).+' "$COMMIT_MSG_FILE" | head -1)

if [ -n "$PROMPT_ID" ]; then
    # Read API port from workflow config, fall back to default
    API_PORT=7277
    PORT_FILE="$PROJECT_ROOT/.ai-workflow/config/api-port"
    [ -f "$PORT_FILE" ] && API_PORT=$(cat "$PORT_FILE")

    # Capture staged files for the audit trail
    CHANGED_FILES=$(git diff --cached --name-only | tr '\n' ',' | sed 's/,$//')

    # Fire-and-forget — don't block the commit if HuminLoop is down
    curl -s -X PATCH \
        "http://127.0.0.1:${API_PORT}/api/workflow/prompts/$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PROMPT_ID}'))" 2>/dev/null || echo "${PROMPT_ID}")" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"DONE\",\"files\":\"${CHANGED_FILES}\"}" \
        --connect-timeout 2 \
        --max-time 5 \
        > /dev/null 2>&1 &
fi
```

- [ ] **Step 2: Update this project's hook**

Append the Prompt ID tracking to the existing `.git/hooks/prepare-commit-msg` after the Python section.

- [ ] **Step 3: Commit**

```bash
git add workflow-templates/hooks/prepare-commit-msg
git commit -m "feat: add Prompt ID parsing to prepare-commit-msg hook template"
```

---

## Task 14: CSS Styles for Dev Features

**Files:**
- Modify: `renderer/styles.css` (or equivalent)

- [ ] **Step 1: Add dev workflow badge styles**

```css
/* Dev workflow status badges */
.badge-captured { background: #6b7280; color: #fff; }
.badge-bundled { background: #f59e0b; color: #000; }
.badge-sent { background: #3b82f6; color: #fff; }
.badge-done { background: #10b981; color: #fff; }
.badge-failed { background: #ef4444; color: #fff; }

.prompt-id-label {
  font-size: 0.7em;
  color: var(--text-dim);
  font-family: monospace;
  margin-left: 4px;
}

.files-badge {
  font-size: 0.7em;
  color: var(--text-dim);
  margin-left: 4px;
  cursor: help;
  border-bottom: 1px dotted var(--text-dim);
}

/* Bundle & Send button */
.bundle-send-btn {
  background: #7c3aed;
  color: #fff;
  border: none;
  border-radius: 4px;
  padding: 2px 8px;
  cursor: pointer;
  font-size: 0.8em;
}
.bundle-send-btn:hover { background: #6d28d9; }
```

- [ ] **Step 2: Add IDE connection styles**

```css
/* IDE connection sidebar */
.ide-connection { padding: 8px 0; border-top: 1px solid var(--border); }
.ide-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
.ide-dot-green { background: #10b981; }
.ide-dot-gray { background: #6b7280; }
.ide-status { display: flex; align-items: center; padding: 4px 0; font-size: 0.85em; }
.pending-badge { font-size: 0.8em; color: #f59e0b; padding: 2px 0; }

/* MCP setup overlay */
.mcp-setup-overlay {
  position: fixed; top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0,0,0,0.5); z-index: 1000;
  display: flex; align-items: center; justify-content: center;
}
.mcp-setup-panel {
  background: var(--bg-card); border-radius: 8px; padding: 20px;
  max-width: 600px; width: 90%;
}
.mcp-config-preview {
  background: var(--bg-main); padding: 12px; border-radius: 4px;
  font-size: 0.85em; overflow-x: auto; max-height: 300px;
}
.mcp-setup-actions { display: flex; gap: 8px; margin-top: 12px; }
```

- [ ] **Step 3: Add annotation color settings styles**

```css
/* Annotation color settings */
.annotation-color-row {
  display: flex; align-items: center; gap: 6px; margin-bottom: 6px;
}
.annotation-color-row input[type="color"] { width: 36px; height: 28px; border: none; cursor: pointer; }
.color-id-input { width: 60px; }
.color-label-input { flex: 1; }
.color-short-input { width: 70px; }
.color-move-btn { padding: 2px 6px; font-size: 0.8em; }

/* Dev filter bar */
.dev-filter-bar { display: flex; gap: 4px; margin-bottom: 8px; }
```

- [ ] **Step 4: Commit**

```bash
git add renderer/styles.css
git commit -m "style: add CSS for dev workflow badges, IDE connection, annotation colors"
```

---

## Task 15: Queue as Plan — Subagent-Driven Flow

**Files:**
- Modify: `src/main.js` (new IPC handlers)
- Modify: `src/preload.js` (expose methods)
- Modify: `renderer/index.js` (UI for queue, progress, advance/cancel)
- Modify: `renderer/styles.css` (plan progress styles)

- [ ] **Step 1: Add queue-as-plan IPC handler in main.js**

```javascript
// ── Plan Queue State ──
// Active plans: { planId: { projectId, tasks: [{ clipId, promptId, status }], currentIndex: 0 } }
const activePlans = new Map();

ipcMain.handle('queue-as-plan', async (_, clipIds, projectId) => {
  if (!Array.isArray(clipIds) || clipIds.length < 2) throw new Error('Need at least 2 clips for a plan');
  if (!projectId) throw new Error('project_id required');
  const project = await db.getProject(projectId);
  if (!project || !project.repo_path) throw new Error('Project has no repo_path');

  const scope = deriveScope(await db.getClip(clipIds[0]), project);
  const annotationColors = await db.getSettings('annotation_colors');
  const tasks = [];

  // Generate all prompt IDs upfront (same batch, sequential letters)
  const firstPromptId = generatePromptId(scope);
  const planId = firstPromptId; // First task's ID identifies the plan

  for (let i = 0; i < clipIds.length; i++) {
    const clip = await db.getClip(clipIds[i]);
    if (!clip) continue;

    const promptId = i === 0 ? firstPromptId : generatePromptId(scope);
    const parentId = i === 0 ? null : firstPromptId;
    const status = i === 0 ? 'BUNDLED' : 'QUEUED';
    const desc = `[Plan ${i + 1}/${clipIds.length}] ${(clip.comment || '(screenshot)').slice(0, 60)}`;

    // Log to tracker
    appendToPromptTracker(project.repo_path, promptId, desc, 'CRAFTED');
    // Update status (first task = BUNDLED, rest = QUEUED)
    if (status === 'QUEUED') {
      updatePromptStatus(project.repo_path, promptId, 'QUEUED');
    }

    await db.updateClip(clipIds[i], { prompt_id: promptId });
    tasks.push({ clipId: clipIds[i], promptId, parentId, status });
  }

  // Write only the first task's file
  const firstClip = await db.getClip(clipIds[0]);
  const bundle = workflowContext.assembleBundle(project.repo_path, firstClip, project);
  const markdown = formatBundle(firstPromptId, firstClip, bundle, annotationColors);

  const contextDir = path.join(project.repo_path, '.ai-workflow', 'context');
  if (!fs.existsSync(contextDir)) fs.mkdirSync(contextDir, { recursive: true });

  const safeId = firstPromptId.replace(/:/g, '-');
  fs.writeFileSync(path.join(contextDir, `IDE_PROMPT_${safeId}.md`), markdown, 'utf8');

  const dataUrl = images.loadImage(clipIds[0]);
  if (dataUrl) {
    const base64 = dataUrl.replace(/^data:image\/\w+;base64,/, '');
    fs.writeFileSync(path.join(contextDir, `ide-prompt-image-${safeId}.png`), Buffer.from(base64, 'base64'));
  }

  // Store active plan
  activePlans.set(planId, { projectId, repoPath: project.repo_path, tasks, currentIndex: 0 });

  addAuditEntry('queue-plan', `Plan ${planId}: ${tasks.length} tasks queued for ${project.name}`);
  notifyMainWindow('clips-changed');
  return { success: true, planId, taskCount: tasks.length };
});
```

- [ ] **Step 2: Add updatePromptStatus helper in main.js**

```javascript
function updatePromptStatus(repoPath, promptId, newStatus, files = null) {
  const trackerPath = path.join(repoPath, '.ai-workflow', 'context', 'PROMPT_TRACKER.log');
  try {
    const raw = fs.readFileSync(trackerPath, 'utf8');
    const lines = raw.split('\n');
    const newLines = lines.map(line => {
      if (line.startsWith(promptId + '|')) {
        const parts = line.split('|');
        parts[1] = newStatus;
        if (files) {
          while (parts.length < 7) parts.push('');
          parts[6] = Array.isArray(files) ? files.join(',') : files;
        }
        return parts.join('|');
      }
      return line;
    });
    fs.writeFileSync(trackerPath, newLines.join('\n'), 'utf8');
  } catch {}
}
```

- [ ] **Step 3: Add advance-plan IPC handler**

```javascript
ipcMain.handle('advance-plan', async (_, planId) => {
  const plan = activePlans.get(planId);
  if (!plan) throw new Error('Plan not found');

  const nextIndex = plan.currentIndex + 1;
  if (nextIndex >= plan.tasks.length) {
    activePlans.delete(planId);
    return { success: true, complete: true };
  }

  const task = plan.tasks[nextIndex];
  const clip = await db.getClip(task.clipId);
  const project = await db.getProject(plan.projectId);
  const annotationColors = await db.getSettings('annotation_colors');
  const bundle = workflowContext.assembleBundle(plan.repoPath, clip, project);
  const markdown = formatBundle(task.promptId, clip, bundle, annotationColors);

  const contextDir = path.join(plan.repoPath, '.ai-workflow', 'context');
  const safeId = task.promptId.replace(/:/g, '-');
  fs.writeFileSync(path.join(contextDir, `IDE_PROMPT_${safeId}.md`), markdown, 'utf8');

  const dataUrl = images.loadImage(task.clipId);
  if (dataUrl) {
    const base64 = dataUrl.replace(/^data:image\/\w+;base64,/, '');
    fs.writeFileSync(path.join(contextDir, `ide-prompt-image-${safeId}.png`), Buffer.from(base64, 'base64'));
  }

  // Update tracker
  updatePromptStatus(plan.repoPath, task.promptId, 'BUNDLED');
  await db.updateClip(task.clipId, { sent_to_ide_at: new Date().toISOString() });
  plan.currentIndex = nextIndex;

  addAuditEntry('advance-plan', `Plan ${planId}: advanced to task ${nextIndex + 1}/${plan.tasks.length}`);
  notifyMainWindow('clips-changed');
  return { success: true, complete: false, currentTask: nextIndex + 1, totalTasks: plan.tasks.length };
});
```

- [ ] **Step 4: Add cancel-plan IPC handler**

```javascript
ipcMain.handle('cancel-plan', async (_, planId) => {
  const plan = activePlans.get(planId);
  if (!plan) throw new Error('Plan not found');

  // Mark remaining QUEUED tasks as FAILED
  for (let i = plan.currentIndex + 1; i < plan.tasks.length; i++) {
    updatePromptStatus(plan.repoPath, plan.tasks[i].promptId, 'FAILED');
  }

  activePlans.delete(planId);
  addAuditEntry('cancel-plan', `Plan ${planId}: cancelled with ${plan.tasks.length - plan.currentIndex - 1} remaining tasks`);
  notifyMainWindow('clips-changed');
  return { success: true };
});

// Expose active plans for renderer
ipcMain.handle('get-active-plans', async () => {
  const plans = [];
  for (const [planId, plan] of activePlans) {
    plans.push({
      planId,
      projectId: plan.projectId,
      tasks: plan.tasks.map(t => ({ clipId: t.clipId, promptId: t.promptId, status: t.status })),
      currentIndex: plan.currentIndex,
      totalTasks: plan.tasks.length,
    });
  }
  return plans;
});
```

- [ ] **Step 5: Add preload methods**

```javascript
queueAsPlan: (clipIds, projectId) => ipcRenderer.invoke('queue-as-plan', clipIds, projectId),
advancePlan: (planId) => ipcRenderer.invoke('advance-plan', planId),
cancelPlan: (planId) => ipcRenderer.invoke('cancel-plan', planId),
getActivePlans: () => ipcRenderer.invoke('get-active-plans'),
```

- [ ] **Step 6: Add auto-advance to polling in renderer/index.js**

Update the `startDevPolling` interval to check for plan advancement:

```javascript
devPollInterval = setInterval(async () => {
  if (!isDevMode || !isFocusedMode) return;

  const oldPrompts = JSON.stringify(devPrompts);
  devPrompts = await window.quickclip.getWorkflowPrompts();

  // Auto-advance plans if relay mode is auto
  const plans = await window.quickclip.getActivePlans();
  for (const plan of plans) {
    const currentTask = plan.tasks[plan.currentIndex];
    const prompt = devPrompts.find(p => p.id === currentTask?.promptId);
    if (prompt?.status === 'DONE') {
      const relayMode = await window.quickclip.getSetting('relay_mode_override');
      // Check relay mode from workflow status
      const wfStatus = await window.quickclip.getWorkflowStatus();
      if (wfStatus.relayMode === 'auto') {
        await window.quickclip.advancePlan(plan.planId);
      }
    }
  }

  if (JSON.stringify(devPrompts) !== oldPrompts) {
    renderAll();
  }
}, 12000);
```

- [ ] **Step 7: Add "Queue as Plan" button to multi-select actions in renderer**

Next to the existing "Bundle & Send" multi-select button:

```javascript
if (isDevMode && selectMode && selectedClipIds.size >= 2) {
  html += `<button class="queue-plan-btn" onclick="queueAsPlan()">&#x1F4CB; Queue as Plan (${selectedClipIds.size} tasks)</button>`;
}
```

```javascript
async function queueAsPlan() {
  if (selectedClipIds.size < 2) return;
  try {
    const result = await window.quickclip.queueAsPlan([...selectedClipIds], selectedProjectId);
    if (result.success) {
      selectMode = false;
      selectedClipIds.clear();
      await loadData();
      renderAll();
    }
  } catch (e) {
    alert('Queue as Plan failed: ' + e.message);
  }
}
```

- [ ] **Step 8: Add plan progress UI to sidebar**

In `renderIdeConnectionSection`, after the pending count:

```javascript
// Plan progress
const plans = window._activePlans || [];
if (plans.length > 0) {
  plans.forEach(plan => {
    const done = plan.tasks.filter(t => {
      const p = devPrompts.find(dp => dp.id === t.promptId);
      return p?.status === 'DONE';
    }).length;
    html += `<div class="plan-progress">`;
    html += `<div class="plan-label">Plan: ${done}/${plan.totalTasks} tasks</div>`;
    html += `<div class="plan-bar"><div class="plan-bar-fill" style="width:${(done/plan.totalTasks)*100}%"></div></div>`;

    // Manual advance button (review mode)
    const currentTask = plan.tasks[plan.currentIndex];
    const currentPrompt = devPrompts.find(p => p.id === currentTask?.promptId);
    if (currentPrompt?.status === 'DONE' && plan.currentIndex < plan.totalTasks - 1) {
      html += `<button class="btn-primary btn-sm" onclick="advancePlan('${escAttr(plan.planId)}')">Send next task</button>`;
    }

    html += `<button class="btn-danger btn-sm" onclick="cancelPlan('${escAttr(plan.planId)}')">Cancel plan</button>`;
    html += `</div>`;
  });
}
```

Fetch active plans in loadData and store for rendering:
```javascript
if (isDevMode) {
  window._activePlans = await window.quickclip.getActivePlans();
}
```

- [ ] **Step 9: Add plan progress styles to CSS**

```css
/* Plan progress */
.plan-progress { padding: 6px 0; border-top: 1px solid var(--border); }
.plan-label { font-size: 0.85em; margin-bottom: 4px; }
.plan-bar { background: var(--bg-main); border-radius: 4px; height: 6px; overflow: hidden; }
.plan-bar-fill { background: #10b981; height: 100%; transition: width 0.3s; }
.btn-sm { font-size: 0.75em; padding: 2px 8px; margin-top: 4px; margin-right: 4px; }
.btn-danger { background: #ef4444; color: #fff; border: none; border-radius: 4px; cursor: pointer; }
.btn-danger:hover { background: #dc2626; }
.queue-plan-btn {
  background: #6d28d9; color: #fff; border: none; border-radius: 4px;
  padding: 4px 10px; cursor: pointer; font-size: 0.85em;
}
.queue-plan-btn:hover { background: #5b21b6; }
```

- [ ] **Step 10: Add QUEUED badge to clip card rendering**

In Task 10's badge class map, add:
```javascript
'QUEUED': 'badge-queued',
```

In CSS:
```css
.badge-queued { background: #8b5cf6; color: #fff; }
```

- [ ] **Step 11: Add advancePlan and cancelPlan JS handlers**

```javascript
async function advancePlan(planId) {
  try {
    await window.quickclip.advancePlan(planId);
    await loadData();
    renderAll();
  } catch (e) {
    alert('Advance plan failed: ' + e.message);
  }
}

async function cancelPlan(planId) {
  if (!confirm('Cancel remaining tasks in this plan?')) return;
  try {
    await window.quickclip.cancelPlan(planId);
    await loadData();
    renderAll();
  } catch (e) {
    alert('Cancel plan failed: ' + e.message);
  }
}
```

- [ ] **Step 12: Commit**

```bash
git add src/main.js src/preload.js renderer/index.js renderer/styles.css
git commit -m "feat: add Queue as Plan — subagent-driven sequential task dispatch"
```

---

## Task 16: Version Bump + Final Integration Test

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Bump version**

In `package.json`, change:
```json
"version": "2.0.0"
```

- [ ] **Step 2: Full integration test**

Run `npm start` and verify:

1. App launches → migration runs if needed (check console for "[HuminLoop] Running v1 → v2 migration...")
2. Switch to Focused mode via tray
3. Select a project with `repo_path` pointing to a repo WITH `.ai-workflow/`
4. Verify "Focused — Dev" label in header
5. Verify IDE Connection section in sidebar
6. Capture a screenshot → verify clip appears with normal Focused behavior
7. Wait for AI prompt generation → verify "Bundle & Send" button appears
8. Click "Bundle & Send" → verify `IDE_PROMPT_*.md` written to project's `.ai-workflow/context/`
9. Verify PROMPT_TRACKER.log has new entry with BUNDLED status
10. Verify clip card shows BUNDLED badge
11. Open Settings → verify Annotation Colors section
12. Try adding a custom color, editing labels
13. Test with a project WITHOUT `.ai-workflow/` → verify "Set up Dev Workflow" button
14. Click it → verify `.ai-workflow/` created with all expected files
15. Verify IDE connection detection (if VS Code + Claude Code installed)
16. If configured, verify "Connect HuminLoop" → preview → Apply writes `.vscode/mcp.json`
17. Multi-select 3+ clips → verify "Queue as Plan" button appears
18. Click "Queue as Plan" → verify first task dispatched, others show QUEUED
19. Simulate task 1 DONE (manually edit PROMPT_TRACKER) → verify auto-advance sends task 2 (relay=auto)
20. Test cancel plan → verify remaining tasks marked FAILED
21. Test with relay=review → verify "Send next task" button appears instead of auto-advance

- [ ] **Step 3: Commit**

```bash
git add package.json
git commit -m "chore: bump version to 2.0.0 for dev workflow integration release"
```

# Dev Workflow Integration — Design Spec

**Date:** 2026-04-09
**Status:** Approved
**Version:** HuminLoop v2.0.0
**Scope:** Integrate multi-agent AI dev workflow into HuminLoop Focused mode

---

## 1. Overview

HuminLoop becomes the **context aggregator and delivery system** for a multi-agent AI dev workflow. Instead of adding AI reasoning costs, it bundles everything the Architect agent (Claude Code) needs — screenshot, annotations, user note, project context, git state, session data — into a structured payload delivered via a file-based bridge. The Architect does the thinking using compute the user is already paying for.

### Principles

- **No new API costs.** Context bundling is pure file reads + existing Gemini annotation interpretation.
- **Convention over configuration.** Dev features activate automatically when `.ai-workflow/` exists in a project's repo path.
- **MCP-only IDE support.** No fallback for IDEs without MCP servers. VScode + Claude Code extension  is the first (and initially only) supported IDE.
- **Shell script compatibility.** HuminLoop reads/writes the same file formats as the existing `.ai-workflow/scripts/`. Both can coexist.

### Two Modes

- **Full** — General knowledge capture. Unchanged.
- **Focused** — Project-focused capture (renamed from "Lite"). When the active project's `repo_path` contains `.ai-workflow/`, dev workflow features activate automatically. The clip list becomes a prompt pipeline with lifecycle tracking.

---

## 2. Context Bundle

When a user clicks "Bundle & Send" on a clip (or multi-selected clips) in Focused mode with dev features active, HuminLoop assembles a structured context bundle.

### Bundle Contents

| Source | Data | Implementation |
|--------|------|----------------|
| Capture | Screenshot image | Existing — saved on disk |
| Capture | Annotation color interpretation | Existing — `ai.generateFocusedPrompt()` output, with dynamic color labels |
| Capture | User's note (raw intent) | Existing — clip `comment` field |
| Project | Active project name, repo_path | Existing — DB project record |
| Git | Current branch, last 5 commits, dirty file list | **New** — `workflow-context.js` gets `getGitState(repoPath)` |
| Workflow | SESSION.md contents | Existing — `workflow-context.js` |
| Workflow | AUDIT_LOG.md recent findings | Existing — `workflow-context.js` |
| Workflow | Pending prompts from PROMPT_TRACKER.log | **New** — `workflow-context.js` gets `getPendingPrompts(repoPath)` |
| Workflow | RELAY_MODE state | Existing — file read |

### Bundle Format (IDE_PROMPT_{promptId}.md)

```markdown
# HuminLoop Dev Prompt
## Prompt ID: scope:HHMM:MMDD:letter

## User Intent
[raw note from capture]

## AI Interpretation
[output from generateFocusedPrompt() — annotation-aware coding prompt]

## Screenshot
[attached separately as ide-prompt-image-{promptId}.png]

## Annotation Guide
- Red (#FF0000) — Delete / Remove / Error: [areas marked]
- Green (#00FF00) — Add / Insert: [areas marked]
- Pink (#FF69B4) — Identify / Reference: [areas marked]
[additional custom colors as configured]

## Project Context
- Project: {project.name}
- Branch: {git.branch}
- Last commits:
  - {hash} {message}
  - ...

## Dirty Files
- {file} ({status})
- ...

## Session State
[SESSION.md contents]

## Pending Work
[CRAFTED/SENT prompts still in flight from PROMPT_TRACKER.log]

## Recent Audit Findings
[last AUDIT_LOG.md entry]
```

### File Naming

Files are named with the Prompt ID to support queuing:
- `IDE_PROMPT_{promptId}.md`
- `ide-prompt-image-{promptId}.png`

This prevents the overwrite bug in the current single-file approach. The MCP `get_pending_prompt` tool scans for `IDE_PROMPT_*.md` files and returns the oldest first (FIFO). Each file is deleted after consumption (one-shot delivery, unchanged behavior).

### Prompt ID Generation

Moves from shell script (`prompt-tracker.sh`) to JavaScript in main.js. Same format: `scope:HHMM:MMDD:letter`.

**Scope derivation:**
1. If clip has a category matching a component label (from project conventions), use that label
2. Else slugify the project name
3. User can override scope in the "Bundle & Send" UI (optional text field, auto-populated)

**Batch letter:** Sequential per session (a, b, c...). Counter resets on app restart or manual `batch-start`.

**Compatibility:** Both JS and shell script write the same `PROMPT_TRACKER.log` format (`ID|STATUS|TIMESTAMP|DESCRIPTION|TYPE|PARENT_ID`). Append-only writes for new entries. Status updates go through HuminLoop's API endpoint only.

---

## 3. Clip List as Prompt Pipeline

In Focused mode with dev features active, the existing clip list gains workflow state inline. No separate view.

### Clip Card Enrichments

| Element | Behavior |
|---------|----------|
| **Status badge** | Lifecycle state: CAPTURED (gray) → BUNDLED (yellow) → SENT (blue) → DONE (green) |
| **Prompt ID** | Displayed on cards that have been bundled |
| **"Bundle & Send" button** | Replaces "Send to IDE" for dev-enabled projects. Assembles context bundle, writes files, logs to PROMPT_TRACKER |
| **Scope field** | Small text input on the Bundle & Send action, auto-populated, editable |

### Header & Sidebar Enrichments

| Element | Behavior |
|---------|----------|
| **Mode label** | "Focused — Dev" when dev features active |
| **IDE connection indicator** | Green dot = Claude Code heartbeated within 60s. Gray = disconnected |
| **Pending prompt count** | Badge showing BUNDLED + SENT count |
| **IDE Connection section** | Sidebar section with detect/config/status (see Section 5) |

### Filtering

The existing clip filter gains workflow status options:
- **All** — all clips (default)
- **Pending** — CAPTURED + BUNDLED + SENT
- **Done** — DONE status

This layers on top of the existing show/hide completed toggle.

### Multi-Clip Bundling

Select multiple clips → "Bundle & Send" combines their context into one payload with one Prompt ID. Reuses the existing `combineAndSendToIde` pattern but with the enriched context bundle format.

### Queue as Plan (Subagent-Driven Flow)

Select multiple clips in order → **"Queue as Plan"** creates N sequential prompts instead of one combined prompt. Each clip becomes an independent task dispatched one at a time.

**How it works:**

1. User multi-selects clips in desired execution order
2. Clicks **"Queue as Plan"**
3. HuminLoop creates N prompt tracker entries, all sharing a `PARENT_ID` (the first task's Prompt ID) and sequential batch letters (`a`, `b`, `c`...)
4. Writes ONLY the first task's `IDE_PROMPT_*.md` file to the project workspace
5. Architect picks up task `a` via MCP `get_pending_prompt`, Builder executes, commits with Prompt ID → status DONE
6. **Auto-advance (RELAY_MODE = auto):** HuminLoop detects DONE on task `a` via polling/hook → automatically writes task `b`'s `IDE_PROMPT_*.md`. Architect picks up on next `get_pending_prompt` call.
7. **Manual advance (RELAY_MODE = review):** HuminLoop shows "Task 1 complete — Send next?" button. User reviews the result and clicks to advance.
8. Repeat until all tasks complete

**Why this is subagent-driven:**
- Each task gets its own prompt file — the Architect receives a **fresh** prompt with no context bleed from previous tasks
- Review gate between tasks (when relay = review) prevents cascading errors
- The Architect can `/clear` between tasks for a clean context window
- Each task's affected files are tracked independently in PROMPT_TRACKER

**Queue progress UI:**
- Sidebar shows: "Plan: 2/5 tasks" with a mini progress bar
- Each queued clip card shows its position: "Task 1 of 5 — DONE", "Task 2 of 5 — SENT", "Task 3 of 5 — QUEUED"
- New status: **QUEUED** — task is in the plan but not yet dispatched (file not yet written)

**Status transitions for queued tasks:**

```
QUEUED    — Task is in the plan, waiting for previous task to complete
    ↓ previous task hits DONE (auto) or user clicks "Send next" (review)
BUNDLED   — IDE_PROMPT_{id}.md written for this task
    ↓ Architect calls get_pending_prompt
SENT      — MCP consumed the file
    ↓ Builder commits with Prompt ID
DONE      — Hook updates status, triggers next task advancement
```

**Plan cancellation:** User can cancel remaining queued tasks at any time. Cancellation sets remaining QUEUED tasks to FAILED status and stops auto-advancement.

### Status Transitions

```
CAPTURED  — Clip saved, AI annotation interpretation runs (existing Focused flow)
    ↓ user clicks "Bundle & Send"
BUNDLED   — Context bundle assembled, IDE_PROMPT_{id}.md written, PROMPT_TRACKER logged
    ↓ Architect calls MCP get_pending_prompt
SENT      — MCP server calls PATCH /api/workflow/prompts/:id {status: "SENT"}
    ↓ Builder commits with Prompt ID in message
DONE      — Git hook parses Prompt ID, calls PATCH /api/workflow/prompts/:id {status: "DONE"}
```

### Polling

Renderer polls workflow state every 10-15 seconds when the clip list is visible in a dev-enabled project. Also refreshes on window focus. No websocket needed.

**Auto-advance check:** During each poll cycle, if a plan is active and the current task is DONE, the polling logic calls `advance-plan` to dispatch the next QUEUED task (only when RELAY_MODE = auto). In review mode, the poll detects DONE and shows the "Send next?" button instead.

---

## 4. Prompt Lifecycle & Tracking

### New Components

| Component | What |
|-----------|------|
| `main.js` — `generatePromptId(scope)` | Prompt ID generation in JS. Reads batch counter, generates `scope:HHMM:MMDD:letter`, appends to PROMPT_TRACKER.log |
| `main.js` — `bundle-and-send` IPC handler | Assembles context bundle via `workflow-context.js`, generates Prompt ID, writes `IDE_PROMPT_{id}.md` + image, logs to tracker, updates clip status |
| `api-server.js` — `PATCH /api/workflow/prompts/:id` | Updates prompt status in PROMPT_TRACKER.log. Called by MCP server and git hooks |
| `mcp-server/index.js` — `get_pending_prompt` update | Scans for `IDE_PROMPT_*.md` files (FIFO), returns oldest. After consuming, calls PATCH endpoint to update status to SENT |
| `preload.js` — `bundleAndSend(clipId, scope?)` | Exposed to renderer, calls `bundle-and-send` IPC |
| `main.js` — `queue-as-plan` IPC handler | Creates N linked prompt entries (QUEUED status), writes only the first task's file, stores plan state |
| `main.js` — `advance-plan` IPC handler | Writes next QUEUED task's file when previous hits DONE. Called by polling or user click |
| `main.js` — `cancel-plan` IPC handler | Sets remaining QUEUED tasks to FAILED, stops auto-advancement |
| `preload.js` — `queueAsPlan(clipIds, projectId)` | Exposed to renderer |
| `preload.js` — `advancePlan(planId)` | Exposed to renderer (for manual advance in review mode) |
| `preload.js` — `cancelPlan(planId)` | Exposed to renderer |
| `preload.js` — `bundleAndSendMultiple(clipIds, scope?)` | Multi-clip variant |
| `prepare-commit-msg` hook enhancement | Parses Prompt ID from commit message, calls `PATCH /api/workflow/prompts/:id` with status DONE via HTTP API. Fire-and-forget (does not block commit if API is unavailable) |

### workflow-context.js Extensions

This module becomes the **single source of truth** for all workflow state reads:

| Function | What | Status |
|----------|------|--------|
| `hasWorkflow(repoPath)` | Checks for `.ai-workflow/` directory | Existing |
| `readSessionContext(repoPath)` | Returns SESSION.md contents | Existing |
| `readAuditFindings(repoPath)` | Returns AUDIT_LOG.md contents | Existing |
| `getGitState(repoPath)` | Returns `{ branch, lastCommits, dirtyFiles }` via git CLI | **New** |
| `getPendingPrompts(repoPath)` | Parses PROMPT_TRACKER.log, returns pending entries | **New** |
| `readRelayMode(repoPath)` | Returns RELAY_MODE file contents | **New** |
| `assembleBundle(repoPath, clip, project)` | Orchestrates all reads into a single bundle object | **New** |

### PROMPT_TRACKER.log Format (Extended)

```
ID|STATUS|TIMESTAMP|DESCRIPTION|TYPE|PARENT_ID|FILES
```

- **ID:** `scope:HHMM:MMDD:letter`
- **STATUS:** QUEUED → CRAFTED → BUNDLED → SENT → DONE (or FAILED)
- **TIMESTAMP:** ISO 8601
- **DESCRIPTION:** Brief text from user's note
- **TYPE:** CRAFTED (from HuminLoop) or DIRECT (from shell script)
- **PARENT_ID:** Links follow-ups to original prompt (null for first)
- **FILES:** Comma-separated list of files changed by the resulting commit (populated on DONE)

**Note:** Status BUNDLED is new (between CRAFTED and SENT). CRAFTED now represents prompts created by shell scripts outside HuminLoop. BUNDLED means HuminLoop assembled and delivered the file.

### Affected Files Tracking

When a Builder commits with a Prompt ID, the `prepare-commit-msg` hook captures the list of staged files via `git diff --cached --name-only` and includes them in the PATCH call:

```json
{ "status": "DONE", "files": ["src/main.js", "renderer/index.js"] }
```

The API endpoint appends the files to the PROMPT_TRACKER.log entry as a comma-separated 7th field. The Workflow tab's Prompts view shows "N files changed" on DONE prompts, expandable to see the full list. This creates a complete audit trail: prompt → commit → files changed.

### Concurrent Access Safety

- **New entries:** Append-only via `fs.appendFileSync` (JS) or `echo >>` (shell). Safe for single-line appends.
- **Status updates:** Go through the HTTP API endpoint exclusively. Shell scripts that need to update status call `curl -X PATCH http://127.0.0.1:7277/api/workflow/prompts/{id}` instead of editing the file directly.
- **Full file rewrites** (for status updates): main.js reads the file, modifies the matching line, writes the whole file. Single-writer through the API serializes access.

---

## 5. IDE Auto-Detection & Setup (VS Code + Claude Code Extension)

### Detection Logic

1. Check for VS Code installation: look for `code` CLI on PATH (`code --version`)
2. Check for Claude Code extension: scan `~/.vscode/extensions/` for `anthropic.claude-code-*` directory
3. Check for project-level MCP config: `{repo_path}/.vscode/mcp.json`
4. If config found, check whether `huminloop` MCP server is already registered

### UI — IDE Connection Section (Focused Mode Sidebar)

Visible only when dev features are active (`.ai-workflow/` detected).

**States:**

| State | Display |
|-------|---------|
| Not detected | "VS Code with Claude Code extension not found." + install guidance |
| Detected, not configured | "VS Code + Claude Code found." + [Connect HuminLoop] button |
| Configured, no heartbeat | "Configured. Waiting for connection..." (gray dot) |
| Connected | "Connected" (green dot) + last heartbeat timestamp |

### Connect Flow

1. User clicks "Connect HuminLoop"
2. HuminLoop generates the MCP config JSON for `.vscode/mcp.json`:

```json
{
  "servers": {
    "huminloop": {
      "command": "node",
      "args": ["{absolute_path_to}/mcp-server/index.js"],
      "env": {
        "HUMINLOOP_API_PORT": "7277",
        "PROJECT_ROOT": "{project.repo_path}"
      }
    }
  }
}
```

3. Preview panel shows the config with explanation
4. Two buttons: **"Apply"** (writes to `{repo_path}/.vscode/mcp.json`) and **"Copy"** (clipboard)
5. Apply merges into existing config (doesn't overwrite other MCP servers or settings)

### Per-Project Wiring

Each HuminLoop project has its own `repo_path`. The MCP config sets `PROJECT_ROOT` per project. When user switches active projects in Focused mode, the IDE Connection section reflects that project's config status.

### Heartbeat Integration

Already built. MCP tool calls send heartbeats with IDE detection. The green/gray dot reads the existing `active_in_ide` project state and heartbeat age.

---

## 6. Annotation Color Customization

### Data Model

Stored in DB settings as `annotation_colors`:

```javascript
[
  { id: "red",    hex: "#FF0000", label: "Delete / Remove / Error",          shortLabel: "remove" },
  { id: "green",  hex: "#00FF00", label: "Add / Insert",                     shortLabel: "add" },
  { id: "pink",   hex: "#FF69B4", label: "Identify / Reference / Question",  shortLabel: "reference" }
]
```

### Settings UI

New section in Settings (visible in both Full and Focused modes):
- List of color rows: color swatch (clickable → native color picker), label text field, short label text field, delete button
- "Add Color" button at bottom
- Reorderable (up/down arrows)
- Defaults ship with the three ZoomIT colors

### Where Colors Flow

| Consumer | How |
|----------|-----|
| `ai.js` — `generateFocusedPrompt()` | The prompt template is generated dynamically from the `annotation_colors` setting instead of using hardcoded red/green/pink descriptions |
| Context bundle — Annotation Guide section | Uses custom labels: "{Color} ({hex}) — {label}: [areas marked]" |
| Focused help page | References configured colors dynamically instead of static descriptions |

### Backward Compatibility

If `annotation_colors` setting doesn't exist in DB, falls back to the hardcoded three-color default. Existing clips are unaffected — colors are only used at prompt generation time.

---

## 7. Workflow Scaffolding

HuminLoop ships with bundled workflow templates and can initialize the `.ai-workflow/` directory for any project.

### Bundled Templates

Templates ship inside the app at `workflow-templates/`:

```
workflow-templates/
  instructions/
    SHARED.md       — Project conventions, session protocol, branch model
    ARCHITECT.md    — Orchestration logic, prefix routing, authorization matrix
    BUILDER.md      — Code writing rules, commit format, project-specific conventions
    REVIEWER.md     — Post-commit code review checklist, JSON verdict format
    SCREENER.md     — Pre-commit hooks and AI analysis rules
  scripts/
    prompt-tracker.sh    — Prompt ID generation and status tracking
    ensure-workflow.sh   — Directory bootstrap and validation
    show-status.sh       — Status dashboard
    compose-instructions.sh — Instruction composition utility
    toggle-relay-mode.sh
    toggle-audit-watch.sh
  hooks/
    prepare-commit-msg   — Auto-updates SESSION.md, appends builder summary
```

These are generic templates. During scaffolding, HuminLoop substitutes project-specific values (project name, repo path) into the templates where marked with `{{placeholders}}`.

### "Initialize Dev Workflow" Flow

In Focused mode sidebar, when a project has a `repo_path` but no `.ai-workflow/`:

1. Show **"Set up Dev Workflow"** button with brief explanation
2. User clicks → HuminLoop creates the directory structure:

```
{repo_path}/
  .ai-workflow/
    instructions/   — Copied from templates, project name substituted
    context/
      SESSION.md           — Initialized with current branch + timestamp
      PROMPT_TRACKER.log   — Empty file
      RELAY_MODE           — "review" (default)
      AUDIT_WATCH_MODE     — "off" (default)
      CHANGELOG.md         — Empty with header
      AUDIT_LOG.md         — Empty with header
    scripts/         — Copied from templates
    config/          — Empty (reserved)
```

3. Installs `prepare-commit-msg` hook to `.git/hooks/` (checks for existing hook, appends if needed)
4. Dev features activate immediately — sidebar updates to show IDE Connection section
5. Audit entry logged: "Dev workflow initialized for {project.name}"

### Git Hook Installation

The `prepare-commit-msg` hook is critical for SESSION.md auto-maintenance and prompt lifecycle closing. During scaffolding:

- If no hook exists at `.git/hooks/prepare-commit-msg` → copy template directly
- If a hook already exists → append HuminLoop's hook logic after existing content (with a comment marker `# --- HuminLoop Dev Workflow ---`)
- Hook is made executable (`chmod +x`)

### Packaged App Considerations

In packaged builds (`app.isPackaged`), templates are bundled inside `resources/workflow-templates/`. The scaffolding reads from there. In dev mode, reads from `{project_root}/workflow-templates/`.

---

## 8. Auto-Detection — Dev Features Activation

(Unchanged from earlier — now dependent on Section 7 scaffolding for new projects.)

### Activation Rule

When a project is selected in Focused mode and `hasWorkflow(project.repo_path)` returns true (`.ai-workflow/` directory exists), dev features activate. No settings, no toggles, no wizard step.

### Feature Matrix

| Feature | Without `.ai-workflow/` | With `.ai-workflow/` |
|---------|------------------------|---------------------|
| Clip cards | Normal Focused cards | + Status badge, Prompt ID, "Bundle & Send" button |
| Sidebar | Project info only | + IDE Connection section |
| Header | "Focused" | "Focused — Dev" |
| Clip filtering | Show/hide completed | + Workflow status filter (All/Pending/Done) |
| Context on capture | Screenshot + note + project | + git state, SESSION.md, AUDIT_LOG.md, pending prompts |
| Prompt tracking | None | Full lifecycle (CAPTURED → BUNDLED → SENT → DONE) |

### Detection Timing

1. On project switch — `hasWorkflow(repoPath)` check
2. Cache result per project for the session
3. Re-check on window focus (in case user ran `ensure-workflow.sh` externally)

### Graceful Degradation

If `.ai-workflow/` exists but specific files are missing (no SESSION.md, no PROMPT_TRACKER.log), the bundle includes what's available and omits what isn't. No errors — lighter bundles.

### No Impact on Full Mode

The existing Workflow tab in full mode continues to work unchanged. Dev features in Focused mode are a separate code path reading the same underlying files.

---

## 9. Data Migration (v1.x → v2.0.0)

On first launch after upgrade, main.js runs a one-time migration before any other initialization:

### Migration Steps

1. **Detect:** Check if `app_mode` setting equals `'lite'`. If not found or already `'focused'`, skip migration.
2. **Settings:**
   - `app_mode`: `'lite'` → `'focused'`
   - `lite_active_project` → copy value to `focused_active_project`, delete old key
3. **Clips:** Update all clips where `source = 'lite'` → `source = 'focused'`
4. **Mark complete:** Write `migration_v2_done: true` setting to prevent re-running

### Safety

- Migration is idempotent — safe to run multiple times (checks for `migration_v2_done` first)
- No destructive operations — old setting keys are deleted only after new ones are confirmed written
- If migration fails mid-way, partial state is fine — next launch retries

---

## 10. Git Hook: Prompt ID Parsing

The `prepare-commit-msg` hook is enhanced to close the prompt lifecycle automatically.

### Parsing Logic

After the existing builder summary logic, the hook scans the commit message for a Prompt ID:

```bash
# Regex: lines starting with "# Prompt ID: " followed by the ID
PROMPT_ID=$(grep -oP '(?<=^# Prompt ID: ).+' "$COMMIT_MSG_FILE" | head -1)
```

Format expected: `scope:HHMM:MMDD:letter` (e.g., `viewer:1430:0409:a`)

### API Call

If a Prompt ID is found, capture affected files and fire-and-forget PATCH to update status:

```bash
if [ -n "$PROMPT_ID" ]; then
  # Read port from scaffolding config, fall back to default
  API_PORT=7277
  PORT_FILE="$PROJECT_ROOT/.ai-workflow/config/api-port"
  [ -f "$PORT_FILE" ] && API_PORT=$(cat "$PORT_FILE")

  # Capture staged files for the audit trail
  CHANGED_FILES=$(git diff --cached --name-only | tr '\n' ',' | sed 's/,$//')

  # Fire-and-forget — don't block the commit if HuminLoop is down
  curl -s -X PATCH \
    "http://127.0.0.1:${API_PORT}/api/workflow/prompts/${PROMPT_ID}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"DONE\",\"files\":\"${CHANGED_FILES}\"}" \
    --connect-timeout 2 \
    --max-time 5 \
    > /dev/null 2>&1 &
fi
```

### Behavior

- Commits WITHOUT a Prompt ID → hook does nothing (silent skip)
- HuminLoop not running → curl times out in background, commit proceeds normally
- Multiple Prompt IDs in one commit → only the first is processed (one commit = one prompt)
- Affected files are captured from `git diff --cached --name-only` and sent as a comma-separated string in the PATCH payload

### Port Discovery

During scaffolding (Section 7), HuminLoop writes the current API port to `.ai-workflow/config/api-port`. The hook reads this file. If missing, falls back to `7277`. This handles the rare case where a user changed `HUMINLOOP_API_PORT`.

---

## 11. Implementation Scope Summary

### New Files

| File | Purpose |
|------|---------|
| `workflow-templates/instructions/*.md` | Bundled instruction templates (SHARED, ARCHITECT, BUILDER, REVIEWER, SCREENER) |
| `workflow-templates/scripts/*.sh` | Bundled shell scripts (prompt-tracker, ensure-workflow, etc.) |
| `workflow-templates/hooks/prepare-commit-msg` | Bundled git hook template |

### Modified Files

| File | Changes |
|------|---------|
| `src/workflow-context.js` | Add `getGitState()`, `getPendingPrompts()`, `readRelayMode()`, `assembleBundle()`, `scaffoldWorkflow()` |
| `src/main.js` | Add `generatePromptId()`, `bundle-and-send` IPC handler, `bundle-and-send-multiple` IPC handler, `init-dev-workflow` IPC handler, v2 migration logic |
| `src/api-server.js` | Add `PATCH /api/workflow/prompts/:id` endpoint |
| `src/preload.js` | Add `bundleAndSend()`, `bundleAndSendMultiple()`, `getAnnotationColors()`, `setAnnotationColors()`, `initDevWorkflow()` |
| `src/ai.js` | Rename `generateLitePrompt` → `generateFocusedPrompt`, make prompt color block dynamic from `annotation_colors` setting |
| `mcp-server/index.js` | Update `get_pending_prompt` to scan `IDE_PROMPT_*.md` (FIFO), call PATCH on consume |
| `renderer/index.js` | Focused mode: rename from Lite, add Bundle & Send button, status badges, IDE connection section, workflow filters, annotation color settings UI, dev mode detection |
| `.ai-workflow/scripts/prompt-tracker.sh` | Add note about API-based status updates; keep append functionality |
| `.githooks/prepare-commit-msg` | Add Prompt ID parsing + HTTP PATCH call (fire-and-forget) |

### Not In Scope

- Builder selection logic (Architect's job)
- Prompt refinement AI (Architect's job)
- Audit automation / Screener / Reviewer invocation
- Toolbar color sync with annotation settings
- IDE support beyond VS Code + Claude Code extension
- Full mode changes

### Rename: Lite → Focused

The v2.0.0 release renames "Lite Mode" to "Focused Mode" throughout the codebase. This affects:
- `app_mode` setting: `'lite'` → `'focused'` (with migration for existing users)
- `source` field on clips: `'lite'` → `'focused'`
- `lite_active_project` setting → `focused_active_project`
- All UI labels, CSS classes, IPC handler names, and function names referencing "lite"
- `renderer/lite-capture.html` → `renderer/focused-capture.html`
- `generateLitePrompt()` → `generateFocusedPrompt()` in ai.js
- `autoCategorizeLite()` → `autoCategorizeFocused()` in main.js
- `getLiteClips()` → `getFocusedClips()` in preload/IPC/DB

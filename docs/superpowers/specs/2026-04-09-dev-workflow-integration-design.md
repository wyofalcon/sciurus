# Dev Workflow Integration — Design Spec

**Date:** 2026-04-09
**Status:** Approved
**Scope:** Integrate multi-agent AI dev workflow into HuminLoop lite mode

---

## 1. Overview

HuminLoop becomes the **context aggregator and delivery system** for a multi-agent AI dev workflow. Instead of adding AI reasoning costs, it bundles everything the Architect agent (Claude Code) needs — screenshot, annotations, user note, project context, git state, session data — into a structured payload delivered via a file-based bridge. The Architect does the thinking using compute the user is already paying for.

### Principles

- **No new API costs.** Context bundling is pure file reads + existing Gemini annotation interpretation.
- **Convention over configuration.** Dev features activate automatically when `.ai-workflow/` exists in a project's repo path.
- **MCP-only IDE support.** No fallback for IDEs without MCP servers. Claude Code is the first (and initially only) supported IDE.
- **Shell script compatibility.** HuminLoop reads/writes the same file formats as the existing `.ai-workflow/scripts/`. Both can coexist.

### Two Modes

- **Full** — General knowledge capture. Unchanged.
- **Lite** — Project-focused capture. When the active project's `repo_path` contains `.ai-workflow/`, dev workflow features activate automatically. The clip list becomes a prompt pipeline with lifecycle tracking.

---

## 2. Context Bundle

When a user clicks "Bundle & Send" on a clip (or multi-selected clips) in lite mode with dev features active, HuminLoop assembles a structured context bundle.

### Bundle Contents

| Source | Data | Implementation |
|--------|------|----------------|
| Capture | Screenshot image | Existing — saved on disk |
| Capture | Annotation color interpretation | Existing — `ai.generateLitePrompt()` output, with dynamic color labels |
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
[output from generateLitePrompt() — annotation-aware coding prompt]

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

In lite mode with dev features active, the existing clip list gains workflow state inline. No separate view.

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
| **Mode label** | "Lite Mode — Dev" when dev features active |
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

### Status Transitions

```
CAPTURED  — Clip saved, AI annotation interpretation runs (existing lite flow)
    ↓ user clicks "Bundle & Send"
BUNDLED   — Context bundle assembled, IDE_PROMPT_{id}.md written, PROMPT_TRACKER logged
    ↓ Architect calls MCP get_pending_prompt
SENT      — MCP server calls PATCH /api/workflow/prompts/:id {status: "SENT"}
    ↓ Builder commits with Prompt ID in message
DONE      — Git hook parses Prompt ID, calls PATCH /api/workflow/prompts/:id {status: "DONE"}
```

### Polling

Renderer polls workflow state every 10-15 seconds when the clip list is visible in a dev-enabled project. Also refreshes on window focus. No websocket needed.

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

### PROMPT_TRACKER.log Format (Unchanged)

```
ID|STATUS|TIMESTAMP|DESCRIPTION|TYPE|PARENT_ID
```

- **ID:** `scope:HHMM:MMDD:letter`
- **STATUS:** CRAFTED → BUNDLED → SENT → DONE (or FAILED)
- **TIMESTAMP:** ISO 8601
- **DESCRIPTION:** Brief text from user's note
- **TYPE:** CRAFTED (from HuminLoop) or DIRECT (from shell script)
- **PARENT_ID:** Links follow-ups to original prompt (null for first)

**Note:** Status BUNDLED is new (between CRAFTED and SENT). CRAFTED now represents prompts created by shell scripts outside HuminLoop. BUNDLED means HuminLoop assembled and delivered the file.

### Concurrent Access Safety

- **New entries:** Append-only via `fs.appendFileSync` (JS) or `echo >>` (shell). Safe for single-line appends.
- **Status updates:** Go through the HTTP API endpoint exclusively. Shell scripts that need to update status call `curl -X PATCH http://127.0.0.1:7277/api/workflow/prompts/{id}` instead of editing the file directly.
- **Full file rewrites** (for status updates): main.js reads the file, modifies the matching line, writes the whole file. Single-writer through the API serializes access.

---

## 5. IDE Auto-Detection & Setup (Claude Code)

### Detection Logic

1. Check for `claude` CLI on PATH (`claude --version`)
2. Check for Claude Code config at project level: `{repo_path}/.claude/settings.json`
3. Check for user-level config: `~/.claude.json`
4. If config found, check whether `huminloop` MCP server is already registered

### UI — IDE Connection Section (Lite Sidebar)

Visible only when dev features are active (`.ai-workflow/` detected).

**States:**

| State | Display |
|-------|---------|
| Not detected | "Claude Code not found." + install guidance |
| Detected, not configured | "Claude Code found." + [Connect HuminLoop] button |
| Configured, no heartbeat | "Configured. Waiting for connection..." (gray dot) |
| Connected | "Connected" (green dot) + last heartbeat timestamp |

### Connect Flow

1. User clicks "Connect HuminLoop"
2. HuminLoop generates the MCP config JSON:

```json
{
  "mcpServers": {
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
4. Two buttons: **"Apply"** (writes to `{repo_path}/.claude/settings.json`) and **"Copy"** (clipboard)
5. Apply merges into existing config (doesn't overwrite other MCP servers or settings)

### Per-Project Wiring

Each HuminLoop project has its own `repo_path`. The MCP config sets `PROJECT_ROOT` per project. When user switches active projects in lite mode, the IDE Connection section reflects that project's config status.

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

New section in Settings (visible in both full and lite modes):
- List of color rows: color swatch (clickable → native color picker), label text field, short label text field, delete button
- "Add Color" button at bottom
- Reorderable (up/down arrows)
- Defaults ship with the three ZoomIT colors

### Where Colors Flow

| Consumer | How |
|----------|-----|
| `ai.js` — `generateLitePrompt()` | The `LITE_PROMPT` template is generated dynamically from the `annotation_colors` setting instead of using hardcoded red/green/pink descriptions |
| Context bundle — Annotation Guide section | Uses custom labels: "{Color} ({hex}) — {label}: [areas marked]" |
| Lite help page | References configured colors dynamically instead of static descriptions |

### Backward Compatibility

If `annotation_colors` setting doesn't exist in DB, falls back to the hardcoded three-color default. Existing clips are unaffected — colors are only used at prompt generation time.

---

## 7. Auto-Detection — Dev Features Activation

### Activation Rule

When a project is selected in lite mode and `hasWorkflow(project.repo_path)` returns true (`.ai-workflow/` directory exists), dev features activate. No settings, no toggles, no wizard step.

### Feature Matrix

| Feature | Without `.ai-workflow/` | With `.ai-workflow/` |
|---------|------------------------|---------------------|
| Clip cards | Normal lite cards | + Status badge, Prompt ID, "Bundle & Send" button |
| Sidebar | Project info only | + IDE Connection section |
| Header | "Lite Mode" | "Lite Mode — Dev" |
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

The existing Workflow tab in full mode continues to work unchanged. Dev features in lite mode are a separate code path reading the same underlying files.

---

## 8. Implementation Scope Summary

### New Files

| File | Purpose |
|------|---------|
| None | All changes modify existing files. No new source files needed. |

### Modified Files

| File | Changes |
|------|---------|
| `src/workflow-context.js` | Add `getGitState()`, `getPendingPrompts()`, `readRelayMode()`, `assembleBundle()` |
| `src/main.js` | Add `generatePromptId()`, `bundle-and-send` IPC handler, `bundle-and-send-multiple` IPC handler |
| `src/api-server.js` | Add `PATCH /api/workflow/prompts/:id` endpoint |
| `src/preload.js` | Add `bundleAndSend()`, `bundleAndSendMultiple()`, `getAnnotationColors()`, `setAnnotationColors()` |
| `src/ai.js` | Make `LITE_PROMPT` color block dynamic from `annotation_colors` setting |
| `mcp-server/index.js` | Update `get_pending_prompt` to scan `IDE_PROMPT_*.md` (FIFO), call PATCH on consume |
| `renderer/index.js` | Lite mode: add Bundle & Send button, status badges, IDE connection section, workflow filters, annotation color settings UI, dev mode detection |
| `.ai-workflow/scripts/prompt-tracker.sh` | Add note about API-based status updates; keep append functionality |
| `.githooks/prepare-commit-msg` | Add Prompt ID parsing + HTTP PATCH call (fire-and-forget) |

### Not In Scope

- Builder selection logic (Architect's job)
- Prompt refinement AI (Architect's job)
- Audit automation / Screener / Reviewer invocation
- Toolbar color sync with annotation settings
- IDE support beyond Claude Code
- Full mode changes

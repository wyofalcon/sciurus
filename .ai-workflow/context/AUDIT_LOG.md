# Pre-Feature Audit Log

## 2026-04-09 — Lite to Focused Rename + v2 Migration

- Mechanical rename across 10 files — no duplicated logic introduced
- Dead code identified: `renderer/lite-index.*` (3 files) — orphaned from an earlier abandoned approach where lite mode had its own renderer; current code uses `index.html` with JS-driven tab hiding. Not blocking; left as-is for now.
- `VALID_SOURCES` in db-sqlite.js and db-pg.js updated to include both `'lite'` (backward compat) and `'focused'` (new)
- v2 migration added to main.js: runs once on first launch, updates `app_mode`, `focused_active_project`, and clip `source` field
- `runRaw()` added to DB layer (db.js, db-sqlite.js, db-pg.js) for migration SQL
- PROMPT_TRACKER.log parser updated to include 7th `files` field in both main.js and api-server.js
- Recommendation: Clean up dead `renderer/lite-index.*` files in a future pass

## 2026-04-09 — Auto-detect In IDE Connection State

- **Git helper duplication** in mcp-server/index.js — identical `git()` function defined in both `session_context` and `git_status` handlers (lines 339, 447). Extract to module-level utility.
- **Image load+compress pipeline** repeated 3x in api-server.js (lines 318, 349, 369). Extract to helper.
- **Dead code**: `deleteCategory()` exists in both DB backends but not exported from db.js wrapper — never called anywhere.
- **No existing polling/heartbeat infrastructure** — this feature adds the first connection-tracking mechanism. Design it centrally.

## 2026-04-04 — HuminLoop Lite Mode

- **Workflow file reading duplicated** between main.js IPC handlers and api-server.js (~50 lines). New `workflow-context.js` covers external projects; HuminLoop's own reads should migrate to it over time.
- **Clip save flow duplicated** between main.js `save-clip` handler and api-server.js `POST /api/clips` (~35 lines). Should extract to a shared function.
- **`get-setting` (singular) IPC handler** appears unused — all renderers call `getSettings()` (plural). Safe to remove.
- **`archived` column** still present but soft-delete uses `deleted_at` instead. Low priority cleanup.
- Overlay, toolbar, preload patterns are clean — no duplication or dead code found in files touched by lite mode.
- Recommendation: None of these block lite mode implementation. Address workflow read consolidation and save-flow dedup in a future cleanup pass.

## 2026-04-05 — Multi-Clip Selection + Combined AI Prompt

- **Copy logic duplicated** in 4+ functions (copyPrompt, copyNoteText, copyInline, copySummaryPanel) — each reimplements find-clip + clipboard write + visual feedback. Candidate for `copyToClipboard(text, options)` helper extraction.
- **Image load-and-compress** still duplicated in 5 places (flagged previously) — new combine handler adds a 6th. Should extract to shared helper.
- No existing multi-select or batch selection patterns found — clean slate for new implementation.
- Existing `ai.summarizeNotes()` generates per-note prompts (sequential calls). New `generateCombinedPrompt()` sends all notes in one Gemini call — different approach, no conflict.
- No dead code found in AI module, renderer clip rendering, or IPC handlers.
- Recommendation: Extract image-compress helper and copy-to-clipboard helper in a future cleanup pass.

## 2026-04-06 — Prompt Filter + Sent-to-IDE Indicator

- No duplicated filtering logic — each filter (status, category, tags, completion) is distinct
- No dead code in clip/prompt handling — all `aiFixPrompt` references are active
- "Show completed" toggle is the ideal template for the new filter (state var → toggle → filter in renderProjectDetail)
- Prompt checks (`!!c.aiFixPrompt`) used consistently across main.js, renderer, summary panel
- Workflow prompt filter (Pending/Done) is separate data model — no conflict
- No schema changes needed for prompt filter (aiFixPrompt already in CLIPS_BASE_QUERY); new `sent_to_ide_at` column required
- Recommendation: Follow the hideCompleted pattern exactly for the new prompt filter

## 2026-04-05 — Auto-Copy Lite Prompt to Clipboard

- **Image load-and-compress pattern duplicated** in 5 places in main.js — candidate for extraction to a helper
- **Field name inconsistency** in `update-clip` and `retrigger-ai` handlers: uses `clip.windowTitle`/`clip.processName` but DB returns `window_title`/`process_name` — causes metadata loss on AI re-runs
- No dead code found; no existing clipboard auto-copy logic to conflict with
- Recommendation: Extract image compress helper and fix field name bug in a future pass

## 2026-04-03 — Workflow Context Reader utility module

- `main.js` and `api-server.js` both contain inline `.ai-workflow` path reads (duplicated pattern) — new module targets a different use case (arbitrary repoPath) so no refactor needed now, but future callers should use `workflow-context.js` instead of reimplementing
- No existing `workflow-context.js` or equivalent utility found — new file is net-new, no dead code risk
- Recommendation: over time, refactor HuminLoop's own workflow reads in `main.js` and `api-server.js` to use a `hasWorkflow('.')` call from this module for consistency

## 2026-04-01 — Workflow toggle switches & clickable prompt cards

- 3 unused preload methods found (getGeneralClips, getClipsForProject, saveCategories) — not blocking, unrelated to workflow
- Toggle pattern inconsistency: toggleBlock/toggleCustomBlock rebuild entire state vs toggleStatus patches directly
- Workflow renderer functions are clean, no duplication
- All 3 workflow IPC handlers actively used
- Recommendation: new IPC handlers for relay/audit toggle rather than shelling out to bash scripts

## 2026-04-01 — Floating Annotation Toolbar (static shell)

- CSS custom properties (`--bg-card`, `--text-primary`, `--text-dim`, `--border-subtle`, `--radius-sm`, `--radius-md`, `--transition-fast`) duplicated between toolbar.css and capture.css/index.css — no shared stylesheet exists; acceptable as toolbar is a separate window with minimal token subset
- `.drag`, `.nd`, `.hidden` utility classes duplicated across capture.css, index.css, and now toolbar.css — same pattern used intentionally per existing convention; no shared base stylesheet
- `onProjectsChanged` IPC listener used in both index.js and toolbar.js — distinct consumers, no duplication concern
- No dead code introduced; toolbar.js stubs call IPC methods not yet in preload.js (expected, deferred to Task 2)
- Recommendation: consider a shared `toolbar-base.css` if a 4th renderer window is added

## 2026-04-01 — Audits section in Workflow tab

- No overlap between existing audit ledger (clip CRUD tracking, max 200 entries in memory) and new pre-feature audit log (markdown file in .ai-workflow/context/)
- .ai-workflow/context/ has 4 existing files: AUDIT_WATCH_MODE, CHANGELOG.md, RELAY_MODE, SESSION.md
- Workflow sidebar sections follow consistent pattern: array of {id, label} objects
- No dead code in workflow rendering functions

## 2026-04-06 — Send to IDE Feature

**Duplicated patterns identified:**

1. **Workflow file reading duplicated across layers** (api-server.js, main.js)
   - `get-workflow-status`, `get-workflow-changelog`, `get-workflow-prompts`, `get-workflow-audits` are identical in both files (~40 lines total)
   - Both read from `.ai-workflow/context/{RELAY_MODE, CHANGELOG.md, PROMPT_TRACKER.log, AUDIT_LOG.md}`
   - Pattern: inline path construction + `fs.readFileSync` with try-catch fallback
   - Impact: New send-to-ide feature will need these files — recommend extracting to a shared utility before adding new endpoints
   - Recommendation: Create `src/workflow-reader.js` module with `getWorkflowStatus()`, `getChangelog()`, `getPrompts()`, `getAudits()` functions; use in both main.js and api-server.js

2. **Image load-and-compress pattern duplicated in 6+ places** (main.js)
   - Lines 544, 594, 718-719, 780-781, 882-887, 920-926 all follow: `images.loadImage()` + `images.compressForAI()`
   - Used in: autoCategorize, autoCategorizeLite, update-clip handler, assign-clip-to-project, summarize-project, combine-clips-prompt
   - Send-to-IDE feature will add more: `POST /api/clips/:id/send-to-ide`, `POST /api/ai/combine-and-send` both need this pattern
   - Recommendation: Extract to `imageWithCompression(clipId)` helper in main.js or a new module

3. **Clip save logic duplicated** between main.js and api-server.js
   - `save-clip` IPC handler (lines 630-683) and `POST /api/clips` endpoint (lines 108-135) both:
     - Save image to disk, set flag to `__on_disk__`
     - Run rules categorization (duplicate: lines 651-661 vs 120-124)
     - Trigger AI async (duplicate: lines 669-681 vs 130-133)
   - Send-to-IDE may need to save clips via new API endpoint — duplication will increase
   - Recommendation: Already flagged in 2026-04-04 audit; extract to shared function before new feature

**New endpoints don't conflict with existing code:**

- `GET /api/clips/:id/image` — new endpoint, no existing image-fetch API (images.loadImage() is internal only)
- `POST /api/clips/:id/send-to-ide` — new action, no similar endpoint exists
- `POST /api/ai/combine-and-send` — new; existing `/api/ai/combine` only returns prompt text, doesn't send anywhere

**MCP tools don't duplicate existing:**

- `project_match` — new; no existing project matching tool
- `get_pending_prompt` — new; similar to `clip_get` but filters for clips without aiFixPrompt
- `clip_get_prompt` — new; similar to `clip_get` but returns just prompt field

**IPC handlers don't duplicate:**

- `sendToIde`, `combineAndSend` — new preload methods, not yet in preload.js

**Existing reusable patterns:**

- `images.loadImage(clipId)` → returns data URL (ready to use)
- `images.compressForAI(dataURL)` → returns compressed JPEG data URL
- `ai.summarizeNotes()` → takes array of {id, comment, imageDataURL} objects
- `ai.generateCombinedPrompt()` → takes same array, returns single text prompt
- `db.getClip(id)` → returns full clip object with all metadata
- `notifyMainWindow()` → sends IPC event to renderer
- `addAuditEntry()` → logs action to audit ledger

**Recommendation: Proceed with feature implementation.** Duplication identified above should be extracted as part of this feature's implementation:

1. Create `src/workflow-reader.js` module (consolidate api-server.js + main.js workflow reads)
2. Extract `imageWithCompression(clipId)` helper in main.js (used by both existing handlers and new send-to-ide)
3. Consider extracting `saveClipWithRules()` helper if new send-to-ide endpoint needs to save clips, but may defer to future pass if not immediately needed

No blocking issues; no dead code conflicts; no orphaned imports to address.

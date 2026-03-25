# Sciurus! — AI-Powered Knowledge Capture

**Sciurus** (Latin: *squirrel*) — also meaning *shadow* and *tail*.

Built by someone with ADHD who needed a way to stash knowledge mid-task
without losing the thread. Like a squirrel burying acorns before darting
to the next tree, Sciurus lets you capture what's on your screen in one
quick motion — screenshot, note, done — and trust that AI will sort it
for you later. The shadow-tail meaning fits too: every idea casts a
shadow you'll want to find again, and this tool is the tail that
follows your train of thought so you don't have to.

### Made for developers who build with AI

When you're using AI-assisted coding tools to debug and build, you
often hit multiple issues in rapid succession — a broken layout here,
a failed API call there, an edge case you'll forget by the time you
fix the first thing. Sciurus was built for exactly this. Screenshot
each issue as you find it, add a quick note, and keep moving. The AI
organizes everything behind the scenes so you can circle back later
with a clean list instead of a foggy memory. Especially useful when
you're working from a laptop with a single screen and can't afford
to context-switch between your app, your terminal, and a notes doc.

## How It Works

1. Press `Ctrl+Shift+Q` (or your MX Master button)
2. Capture popup appears with screenshot preview
3. **Window context auto-captured** — active window title + process name grabbed before the popup opens
4. Type a quick note, optionally pick a category + project
5. **Rule engine runs first** — auto-matches project by repo path and window title
6. **AI fallback** — Gemini 2.5 Flash analyzes the screenshot + note if rules didn't categorize
7. Browse, search, and manage clips in the tabbed notes viewer

## Features

- **Clipboard watcher** — auto-detects new screenshots (1s polling)
- **Window metadata capture** — grabs active window title + process name via Win32 API (Windows) or xdotool/gdbus (Linux)
- **Rule-based categorization** — auto-assign projects by repo path, custom pattern rules with priority
- **Gemini vision AI** — analyzes screenshots + notes for smart categorization (optional)
- **Markup color semantics** — red = bug, green = approved, pink = question (AI reads your annotations)
- **AI search** — natural language search across all clips
- **Dual database backend** — PostgreSQL (Docker) for power users, SQLite (built-in) for zero-setup
- **Disk-based image storage** — screenshots saved to filesystem, not bloating the database
- **Project organization** — group clips by project with dedicated views
- **General Notes + Projects tabs** — tabbed interface for organized browsing
- **System tray** — runs quietly in background
- **Threaded comments** — add follow-up notes to any clip
- **Setup wizard** — 3-step first-run flow: database, AI config, launch
- **Settings panel** — configure capture, AI, and app behavior in-app
- **Cross-platform** — Windows and Linux (AppImage, deb)

## Setup

### Quick start (new users)

Just run the app — the **setup wizard** walks you through everything:

```bash
npm install
npm start
```

The wizard will:
1. Detect Docker or offer the built-in SQLite database (no Docker needed)
2. Help you set up AI (optional — free Gemini API key or GCP Vertex AI)
3. Launch the app

### Linux requirements

For window metadata capture (auto-categorization by active window):

```bash
# X11 / WSLg (recommended)
sudo apt install xdotool

# Wayland + GNOME — works automatically via gdbus (no extra install)
```

Without xdotool, the app still works — you just won't get automatic project matching from window titles.

### Manual setup (power users)

#### Database

**Option A: SQLite (zero setup)**
Set `DB_BACKEND=sqlite` in `.env` or just skip Docker — the app falls back automatically.

**Option B: PostgreSQL (Docker)**
```bash
docker compose up -d
```
This starts PostgreSQL 16 (`sciurus-db`) on port 5433. Data persists in a Docker volume.

#### AI (optional)

**Option A: Gemini API Key (recommended, free tier)**
1. Go to https://aistudio.google.com/apikey
2. Create an API key
3. Add to `.env`: `GEMINI_API_KEY=AIzaSy...`

**Option B: Vertex AI (GCP billing)**
1. Enable the Vertex AI API on your GCP project
2. Create a Service Account, download the JSON key
3. Save as `credentials.json` in the project root
4. Add to `.env`: `AI_AUTH_MODE=vertex`

AI features are optional. The rule engine handles most categorization without AI.

### Environment variables

```bash
# Database: pg, sqlite, or auto (tries pg then sqlite)
DB_BACKEND=pg

# PostgreSQL connection (when using Docker)
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=sciurus
POSTGRES_USER=sciurus
POSTGRES_PASSWORD=sciurus_dev

# AI auth mode: apikey, vertex, or auto
AI_AUTH_MODE=apikey
GEMINI_API_KEY=your-key-here

# Hotkey
HOTKEY_COMBO=ctrl+shift+q
```

## Building

```bash
# Windows installer (.exe)
npm run build:win

# Linux (AppImage + .deb)
npm run build:linux

# Both platforms
npm run build
```

## Tip: One-Button Capture

Sciurus works best when capturing is effortless — one press, no thinking.
Map `Ctrl+Shift+Q` to a spare mouse button or macro key so you can stash
a thought without breaking flow. Works great with PowerToys Zoom Draw
for annotating screenshots with colored markers before capture.

## Categorization Priority Chain

When you save a clip, Sciurus tries to categorize it in this order:

1. **Your manual selection** — always wins
2. **Repo path auto-match** — if the window title contains a project's repo folder name
3. **Window rules** — custom pattern matching on window title or process name
4. **AI fallback** — Gemini analyzes the screenshot + note + window context

Most clips get categorized instantly by rules 2-3, no AI call needed.

## Project Structure

```
sciurus/
├── src/
│   ├── main.js          # Electron main process — tray, hotkey, IPC, capture flow
│   ├── db.js            # Database switcher (PostgreSQL or SQLite)
│   ├── db-pg.js         # PostgreSQL backend (pg)
│   ├── db-sqlite.js     # SQLite backend (better-sqlite3)
│   ├── ai.js            # Gemini AI via API key or Vertex AI (native JWT auth)
│   ├── rules.js         # Rule-based categorization engine with in-memory cache
│   ├── window-info.js   # Cross-platform active window capture (Win32/xdotool/gdbus)
│   ├── images.js        # Disk-based image storage + AI compression
│   └── preload.js       # Context bridge for renderer
├── renderer/
│   ├── index.html/js/css   # Main window — tabbed notes viewer
│   ├── capture.html/js/css # Capture popup
│   └── setup.html/js/css   # First-run setup wizard
├── scripts/
│   └── get-window.ps1   # Windows PowerShell window info script
├── docker/
│   └── init.sql         # PostgreSQL schema + seed data
├── docker-compose.yml   # PostgreSQL 16 container
├── .env                 # Config (git-ignored)
├── credentials.json     # Google service account (git-ignored)
└── package.json
```

## Architecture

- **Storage**: PostgreSQL 16 (Docker) or SQLite (built-in) — auto-detected
- **Images**: Saved to disk (`{userData}/images/`), compressed to JPEG before AI calls
- **AI**: Gemini 2.5 Flash via API key or Vertex AI — with native JWT auth (no heavy SDKs)
- **Rules**: Window title + process name matching with 5-minute cache, regex support
- **Frontend**: Electron with context-isolated renderers
- **Platforms**: Windows (NSIS installer), Linux (AppImage, deb)

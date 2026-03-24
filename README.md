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
3. Type a quick note and hit Enter
4. Gemini 2.5 Flash analyzes the screenshot + note (vision)
5. Auto-categorized, tagged, and saved locally + synced to Google Sheets
6. Browse, search, and manage clips in the main window

## Features

- **Clipboard watcher** — auto-detects new screenshots
- **Gemini vision AI** — analyzes screenshots for smart categorization
- **AI search** — natural language search across all clips
- **Local-first storage** — instant, works offline (electron-store)
- **Google Sheets sync** — background cloud backup
- **System tray** — runs quietly in background
- **Threaded comments** — add follow-up notes to any clip

## Setup

### 1. Install dependencies
```bash
npm install
```

### 2. Google Cloud Setup
- Go to https://console.cloud.google.com/
- Create a project (or use existing)
- Enable the **Vertex AI API** and **Google Sheets API**
- Go to Credentials > Create Credentials > **Service Account**
- Download the JSON key and save as `credentials.json` in this folder

This single service account powers both Gemini AI (via Vertex AI)
and Google Sheets sync — all billed to your GCP credits.

### 3. Google Sheets Sync (optional)

#### Create & Configure the Sheet
Due to Google Cloud restrictions, service accounts start with 0 bytes of
Drive quota and cannot create new files. Create the sheet manually:

1. Go to https://sheets.google.com and create a new blank spreadsheet
2. Click **Share** and add your service account email as **Editor**
   (find the email in `credentials.json` under `client_email`)
3. Copy the Sheet ID from the URL:
   `https://docs.google.com/spreadsheets/d/<SHEET_ID>/edit`
4. Add to `.env`: `GOOGLE_SHEET_ID=<SHEET_ID>`

### 4. Run Sciurus
```bash
npm start
```

## Tip: One-Button Capture

Sciurus works best when capturing is effortless — one press, no thinking.
Map `Ctrl+Shift+Q` to a spare mouse button or macro key so you can stash
a thought without breaking flow. Mice with programmable buttons (like
Logitech's MX Master series) are great for this.

## Project Structure

```
sciurus/
├── src/
│   ├── main.js          # Electron main process — tray, hotkey, IPC, Sheets sync
│   ├── ai.js            # Gemini 2.5 Flash via Vertex AI (vision + text)
│   ├── sheets.js        # Google Sheets background sync
│   └── preload.js       # Context bridge for renderer
├── renderer/
│   ├── index.html       # Main window — clip browser
│   ├── index.js         # Clip list, AI search, filtering
│   ├── index.css        # Main window styles
│   ├── capture.html     # Capture popup
│   ├── capture.js       # Capture popup logic
│   └── capture.css      # Capture popup styles
├── .env                 # API keys (git-ignored)
├── .env.example         # Template for .env
├── credentials.json     # Google service account (git-ignored)
└── package.json
```

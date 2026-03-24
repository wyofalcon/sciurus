// src/sheets.js — Background sync to Google Sheets via service account

const { google } = require('googleapis');
const path = require('path');
const fs = require('fs');

// ── Constants ──

const CREDENTIALS_PATH = path.join(__dirname, '..', 'credentials.json');
const SCOPES = ['https://www.googleapis.com/auth/spreadsheets'];

// ── State ──

let service = null;
let sheetId = null;

// ── Public API ──

/** Initialize the Sheets connection using the service account. */
function init() {
  if (!fs.existsSync(CREDENTIALS_PATH)) {
    console.log('[Sheets] No credentials.json — sync disabled.');
    return false;
  }
  sheetId = process.env.GOOGLE_SHEET_ID;
  if (!sheetId) {
    console.log('[Sheets] No GOOGLE_SHEET_ID — sync disabled.');
    return false;
  }
  try {
    const auth = new google.auth.GoogleAuth({ keyFile: CREDENTIALS_PATH, scopes: SCOPES });
    service = google.sheets({ version: 'v4', auth });
    console.log('[Sheets] Connected.');
    return true;
  } catch (e) {
    console.error('[Sheets] Init failed:', e.message);
    return false;
  }
}

/** Returns true if Sheets sync is configured and ready. */
function isEnabled() {
  return !!service && !!sheetId;
}

/** Read category names from the Categories sheet. */
async function getCategories() {
  if (!isEnabled()) return null;
  try {
    const res = await service.spreadsheets.values.get({
      spreadsheetId: sheetId,
      range: 'Categories!A2:A100',
    });
    return (res.data.values || []).map((row) => row[0]).filter(Boolean);
  } catch (e) {
    console.error('[Sheets] getCategories error:', e.message);
    return null;
  }
}

/** Append a clip to the Snippets sheet and ensure its category exists. */
async function saveClip(clip) {
  if (!isEnabled()) return;
  try {
    const timestamp = new Date().toISOString().replace('T', ' ').slice(0, 19);
    const row = [
      timestamp,
      (clip.comment || '').slice(0, 60),
      clip.category || 'Uncategorized',
      clip.aiSummary || '',
      clip.url || '',
      (clip.tags || []).join(', '),
      clip.comment || '',
      '(local)',
    ];
    await service.spreadsheets.values.append({
      spreadsheetId: sheetId,
      range: 'Snippets!A:H',
      valueInputOption: 'RAW',
      requestBody: { values: [row] },
    });

    // Add new categories to the sheet
    if (clip.category && clip.category !== 'Uncategorized') {
      const existing = await getCategories();
      if (existing && !existing.includes(clip.category)) {
        await service.spreadsheets.values.append({
          spreadsheetId: sheetId,
          range: 'Categories!A:A',
          valueInputOption: 'RAW',
          requestBody: { values: [[clip.category]] },
        });
      }
    }
    console.log(`[Sheets] Synced: ${(clip.comment || '').slice(0, 40)}`);
  } catch (e) {
    console.error('[Sheets] Save error:', e.message);
  }
}

module.exports = { init, isEnabled, getCategories, saveClip };

// src/sheets.js — Background sync to Google Sheets
const { google } = require('googleapis');
const path = require('path');
const fs = require('fs');

let service = null;
let sheetId = null;

function init() {
  const credPath = path.join(__dirname, '..', 'credentials.json');
  if (!fs.existsSync(credPath)) {
    console.log('[Sheets] No credentials.json — sync disabled.');
    return false;
  }
  sheetId = process.env.GOOGLE_SHEET_ID;
  if (!sheetId) {
    console.log('[Sheets] No GOOGLE_SHEET_ID — sync disabled.');
    return false;
  }
  try {
    const auth = new google.auth.GoogleAuth({
      keyFile: credPath,
      scopes: ['https://www.googleapis.com/auth/spreadsheets'],
    });
    service = google.sheets({ version: 'v4', auth });
    console.log('[Sheets] Connected.');
    return true;
  } catch (e) {
    console.error('[Sheets] Init failed:', e.message);
    return false;
  }
}

function isEnabled() {
  return !!service && !!sheetId;
}

async function getCategories() {
  if (!isEnabled()) return null;
  try {
    const res = await service.spreadsheets.values.get({
      spreadsheetId: sheetId,
      range: 'Categories!A2:A100',
    });
    return (res.data.values || []).map((r) => r[0]).filter(Boolean);
  } catch (e) {
    console.error('[Sheets] getCategories error:', e.message);
    return null;
  }
}

async function saveClip(clip) {
  if (!isEnabled()) return;
  try {
    const now = new Date().toISOString().replace('T', ' ').slice(0, 19);
    const row = [
      now,
      (clip.comment || '').slice(0, 60),
      clip.category || 'Uncategorized',
      clip.aiSummary || '',
      '',
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

    // Ensure category exists in sheet
    if (clip.category && clip.category !== 'Uncategorized') {
      const cats = await getCategories();
      if (cats && !cats.includes(clip.category)) {
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

// src/ai.js — AI categorization via Vertex AI Gemini (billed to GCP project)
const fs = require('fs');
const path = require('path');
const { google } = require('googleapis');

const MODEL = 'gemini-2.5-flash';
const LOCATION = 'us-central1';

let authClient = null;
let projectId = null;

function init() {
  const credPath = path.join(__dirname, '..', 'credentials.json');
  if (!fs.existsSync(credPath)) {
    console.log('[AI] No credentials.json — AI disabled.');
    return false;
  }
  try {
    const creds = JSON.parse(fs.readFileSync(credPath, 'utf8'));
    projectId = creds.project_id;
    authClient = new google.auth.GoogleAuth({
      keyFile: credPath,
      scopes: ['https://www.googleapis.com/auth/cloud-platform'],
    });
    console.log(`[AI] Vertex AI ready (project: ${projectId}, model: ${MODEL})`);
    return true;
  } catch (e) {
    console.error('[AI] Init failed:', e.message);
    return false;
  }
}

function isEnabled() {
  return !!authClient && !!projectId;
}

async function callGemini(parts) {
  if (!isEnabled()) return null;

  const token = await authClient.getAccessToken();
  const url = `https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${projectId}/locations/${LOCATION}/publishers/google/models/${MODEL}:generateContent`;

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      contents: [{ parts }],
      generationConfig: { temperature: 0.3, maxOutputTokens: 500 },
    }),
  });

  const data = await res.json();
  if (data.error) {
    throw new Error(data.error.message || JSON.stringify(data.error));
  }
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text || '';
  const clean = text.replace(/```json|```/g, '').trim();
  return JSON.parse(clean);
}

async function categorize(comment, categories, imageDataURL = null) {
  const prompt =
    `You are a knowledge categorization assistant. Analyze the note` +
    (imageDataURL ? ' and the attached screenshot' : '') +
    `. Respond ONLY with valid JSON, no markdown:\n` +
    `{"category":"best fit from ${JSON.stringify(categories)} or create a new broad one",` +
    `"tags":["2-4","short","tags"],"summary":"1-line context, max 12 words"}\n\n` +
    `Note: "${comment}"`;

  const parts = [];
  if (imageDataURL) {
    const base64 = imageDataURL.replace(/^data:image\/\w+;base64,/, '');
    parts.push({ inline_data: { mime_type: 'image/png', data: base64 } });
  }
  parts.push({ text: prompt });

  try {
    return await callGemini(parts);
  } catch (e) {
    console.error('[AI] categorize error:', e.message);
    return null;
  }
}

async function search(query, clips) {
  const clipList = clips
    .map(
      (c) =>
        `ID:${c.id}|Cat:${c.category}|Tags:${(c.tags || []).join(',')}|Comment:${c.comment}|AI:${c.aiSummary || ''}|Extra:${(c.comments || []).map((x) => x.text).join(';')}`
    )
    .join('\n');

  try {
    return await callGemini([
      {
        text: `Find matching clips for: "${query}". Return ONLY a JSON array of IDs, most relevant first. No markdown.\nClips:\n${clipList}`,
      },
    ]);
  } catch (e) {
    console.error('[AI] search error:', e.message);
    return null;
  }
}

module.exports = { init, isEnabled, categorize, search };

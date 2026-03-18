// src/ai.js — AI categorization via Anthropic API
// Reads API key from environment or config file
const fs = require('fs');
const path = require('path');
const https = require('https');

function getApiKey() {
  // Check environment variable first
  if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY;
  // Check config file
  try {
    const cfgPath = path.join(__dirname, '..', '.env');
    const content = fs.readFileSync(cfgPath, 'utf8');
    const match = content.match(/ANTHROPIC_API_KEY=(.+)/);
    if (match) return match[1].trim();
  } catch (e) {}
  return null;
}

function callClaude(prompt) {
  return new Promise((resolve, reject) => {
    const key = getApiKey();
    if (!key) { resolve(null); return; }
    const body = JSON.stringify({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 500,
      messages: [{ role: 'user', content: prompt }],
    });
    const req = https.request({
      hostname: 'api.anthropic.com',
      path: '/v1/messages',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          const text = parsed.content?.map(i => i.text||'').join('') || '';
          const clean = text.replace(/```json|```/g, '').trim();
          resolve(JSON.parse(clean));
        } catch (e) { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.write(body);
    req.end();
  });
}

async function categorize(comment, categories) {
  return callClaude(
    `You categorize quick notes. Respond ONLY with JSON, no markdown:\n`
    + `{"category":"best from ${JSON.stringify(categories)}","tags":["2-4","short","tags"],"summary":"1-line context, max 12 words"}\n\n`
    + `Note: "${comment}"`
  );
}

async function search(query, clips) {
  const clipList = clips.map(c =>
    `ID:${c.id}|Cat:${c.category}|Tags:${(c.tags||[]).join(',')}|Comment:${c.comment}|AI:${c.aiSummary||''}|Extra:${(c.comments||[]).map(x=>x.text).join(';')}`
  ).join('\n');
  return callClaude(
    `Find matching clips for: "${query}". Return ONLY a JSON array of IDs, most relevant first. No markdown.\nClips:\n${clipList}`
  );
}

module.exports = { categorize, search, getApiKey };

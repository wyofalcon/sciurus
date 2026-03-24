/**
 * Sciurus — PostgreSQL data access layer
 * Replaces electron-store + Google Sheets with a local Docker PostgreSQL database.
 */

const { Pool } = require('pg');

let pool = null;
const categoryCache = new Map(); // name → id

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

async function init() {
  pool = new Pool({
    host: process.env.POSTGRES_HOST || 'localhost',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    database: process.env.POSTGRES_DB || 'sciurus',
    user: process.env.POSTGRES_USER || 'sciurus',
    password: process.env.POSTGRES_PASSWORD || 'sciurus_dev',
    max: 10,
    idleTimeoutMillis: 30000,
  });

  // Retry loop — Docker container may still be starting
  for (let attempt = 1; attempt <= 15; attempt++) {
    try {
      const client = await pool.connect();
      client.release();
      console.log('[Sciurus DB] Connected to PostgreSQL');
      await refreshCategoryCache();
      return true;
    } catch (err) {
      console.log(`[Sciurus DB] Connection attempt ${attempt}/15 failed: ${err.message}`);
      if (attempt < 15) await sleep(2000);
    }
  }

  console.error('[Sciurus DB] Could not connect to PostgreSQL after 15 attempts');
  return false;
}

async function close() {
  if (pool) {
    await pool.end();
    pool = null;
  }
}

function isReady() {
  return pool !== null;
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

async function refreshCategoryCache() {
  const { rows } = await pool.query('SELECT id, name FROM categories ORDER BY sort_order');
  categoryCache.clear();
  for (const row of rows) categoryCache.set(row.name, row.id);
}

async function getCategoryId(name) {
  if (!name) return null;
  if (categoryCache.has(name)) return categoryCache.get(name);
  // Insert if new
  const { rows } = await pool.query(
    `INSERT INTO categories (name, sort_order)
     VALUES ($1, (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM categories))
     ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
     RETURNING id`,
    [name]
  );
  categoryCache.set(name, rows[0].id);
  return rows[0].id;
}

async function getCategories() {
  const { rows } = await pool.query('SELECT name FROM categories ORDER BY sort_order');
  return rows.map(r => r.name);
}

async function saveCategory(name) {
  await getCategoryId(name);
}

async function deleteCategory(name) {
  if (name === 'Uncategorized') return;
  const uncatId = categoryCache.get('Uncategorized');
  await pool.query(
    'UPDATE clips SET category_id = $1 WHERE category_id = (SELECT id FROM categories WHERE name = $2)',
    [uncatId, name]
  );
  await pool.query('DELETE FROM categories WHERE name = $1', [name]);
  categoryCache.delete(name);
}

// ---------------------------------------------------------------------------
// Clips
// ---------------------------------------------------------------------------

const CLIPS_BASE_QUERY = `
  SELECT c.id, c.image, c.comment,
         cat.name AS category,
         c.project_id, p.name AS "projectName",
         c.tags, c.ai_summary AS "aiSummary",
         c.url, c.status, c.timestamp,
         COALESCE(
           json_agg(
             json_build_object('text', cc.text, 'ts', cc.ts)
             ORDER BY cc.ts
           ) FILTER (WHERE cc.id IS NOT NULL),
           '[]'
         ) AS comments
  FROM clips c
  LEFT JOIN categories cat ON c.category_id = cat.id
  LEFT JOIN projects p ON c.project_id = p.id
  LEFT JOIN clip_comments cc ON cc.clip_id = c.id
`;

const CLIPS_GROUP = `
  GROUP BY c.id, cat.name, p.name
  ORDER BY c.timestamp DESC
`;

async function getClips(projectId) {
  let query, params;
  if (projectId === undefined) {
    // All clips
    query = CLIPS_BASE_QUERY + CLIPS_GROUP;
    params = [];
  } else if (projectId === null) {
    // General notes (no project)
    query = CLIPS_BASE_QUERY + ' WHERE c.project_id IS NULL ' + CLIPS_GROUP;
    params = [];
  } else {
    query = CLIPS_BASE_QUERY + ' WHERE c.project_id = $1 ' + CLIPS_GROUP;
    params = [projectId];
  }
  const { rows } = await pool.query(query, params);
  return rows;
}

async function getClip(id) {
  const { rows } = await pool.query(
    CLIPS_BASE_QUERY + ' WHERE c.id = $1 ' + CLIPS_GROUP,
    [id]
  );
  return rows[0] || null;
}

async function saveClip(clip) {
  const categoryId = await getCategoryId(clip.category || 'Uncategorized');
  await pool.query(
    `INSERT INTO clips (id, image, comment, category_id, project_id, tags, ai_summary, url, status, timestamp)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
    [
      clip.id,
      clip.image || null,
      clip.comment || '',
      categoryId,
      clip.project_id || null,
      clip.tags || [],
      clip.aiSummary || null,
      clip.url || null,
      clip.status || 'parked',
      clip.timestamp,
    ]
  );
  // Insert any initial comments
  if (clip.comments && clip.comments.length > 0) {
    for (const c of clip.comments) {
      await pool.query(
        'INSERT INTO clip_comments (clip_id, text, ts) VALUES ($1, $2, $3)',
        [clip.id, c.text, c.ts]
      );
    }
  }
  return true;
}

async function updateClip(id, updates) {
  const ALLOWED = ['category', 'tags', 'aiSummary', 'url', 'status', 'comments', 'project_id', 'comment'];
  const setClauses = [];
  const params = [];
  let paramIdx = 1;

  for (const [key, val] of Object.entries(updates)) {
    if (!ALLOWED.includes(key)) continue;

    if (key === 'category') {
      const catId = await getCategoryId(val);
      setClauses.push(`category_id = $${paramIdx++}`);
      params.push(catId);
    } else if (key === 'aiSummary') {
      setClauses.push(`ai_summary = $${paramIdx++}`);
      params.push(val);
    } else if (key === 'tags') {
      setClauses.push(`tags = $${paramIdx++}`);
      params.push(val);
    } else if (key === 'comments') {
      // Replace all comments — delete then re-insert
      await pool.query('DELETE FROM clip_comments WHERE clip_id = $1', [id]);
      if (Array.isArray(val)) {
        for (const c of val) {
          await pool.query(
            'INSERT INTO clip_comments (clip_id, text, ts) VALUES ($1, $2, $3)',
            [id, c.text, c.ts]
          );
        }
      }
      continue; // not a column on clips table
    } else if (key === 'project_id') {
      setClauses.push(`project_id = $${paramIdx++}`);
      params.push(val);
    } else if (key === 'url') {
      setClauses.push(`url = $${paramIdx++}`);
      params.push(val);
    } else if (key === 'status') {
      setClauses.push(`status = $${paramIdx++}`);
      params.push(val);
    } else if (key === 'comment') {
      setClauses.push(`comment = $${paramIdx++}`);
      params.push(val);
    }
  }

  if (setClauses.length > 0) {
    params.push(id);
    await pool.query(
      `UPDATE clips SET ${setClauses.join(', ')} WHERE id = $${paramIdx}`,
      params
    );
  }

  return true;
}

async function deleteClip(id) {
  await pool.query('DELETE FROM clips WHERE id = $1', [id]);
  return true;
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

async function addComment(clipId, text, ts) {
  await pool.query(
    'INSERT INTO clip_comments (clip_id, text, ts) VALUES ($1, $2, $3)',
    [clipId, text, ts]
  );
  return true;
}

async function deleteComment(commentId) {
  await pool.query('DELETE FROM clip_comments WHERE id = $1', [commentId]);
  return true;
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

async function getProjects() {
  const { rows } = await pool.query(`
    SELECT p.*,
           (SELECT COUNT(*) FROM clips WHERE project_id = p.id) AS "clipCount"
    FROM projects p
    ORDER BY p.name
  `);
  return rows;
}

async function getProject(id) {
  const { rows } = await pool.query('SELECT * FROM projects WHERE id = $1', [id]);
  return rows[0] || null;
}

async function createProject(data) {
  const { rows } = await pool.query(
    `INSERT INTO projects (name, description, repo_path, color)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [data.name, data.description || '', data.repo_path || null, data.color || '#3b82f6']
  );
  return rows[0];
}

async function updateProject(id, data) {
  const fields = [];
  const params = [];
  let idx = 1;

  if (data.name !== undefined) { fields.push(`name = $${idx++}`); params.push(data.name); }
  if (data.description !== undefined) { fields.push(`description = $${idx++}`); params.push(data.description); }
  if (data.repo_path !== undefined) { fields.push(`repo_path = $${idx++}`); params.push(data.repo_path); }
  if (data.color !== undefined) { fields.push(`color = $${idx++}`); params.push(data.color); }

  if (fields.length === 0) return null;

  params.push(id);
  const { rows } = await pool.query(
    `UPDATE projects SET ${fields.join(', ')} WHERE id = $${idx} RETURNING *`,
    params
  );
  return rows[0] || null;
}

async function deleteProject(id) {
  // Clips get project_id = NULL (move to General Notes)
  await pool.query('UPDATE clips SET project_id = NULL WHERE project_id = $1', [id]);
  await pool.query('DELETE FROM projects WHERE id = $1', [id]);
  return true;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

async function getSettings(key) {
  const { rows } = await pool.query('SELECT value FROM settings WHERE key = $1', [key]);
  return rows[0] ? rows[0].value : null;
}

async function getAllSettings() {
  const { rows } = await pool.query('SELECT key, value FROM settings');
  const settings = {};
  for (const row of rows) settings[row.key] = row.value;
  return settings;
}

async function saveSetting(key, value) {
  await pool.query(
    `INSERT INTO settings (key, value) VALUES ($1, $2)
     ON CONFLICT (key) DO UPDATE SET value = $2`,
    [key, JSON.stringify(value)]
  );
  return true;
}

// ---------------------------------------------------------------------------
// Migration from electron-store
// ---------------------------------------------------------------------------

async function migrateFromStore(storeData) {
  const { clips, categories } = storeData;
  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    // Migrate categories
    for (const name of categories) {
      await client.query(
        `INSERT INTO categories (name, sort_order)
         VALUES ($1, (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM categories))
         ON CONFLICT (name) DO NOTHING`,
        [name]
      );
    }

    // Refresh cache within transaction
    const catRows = (await client.query('SELECT id, name FROM categories')).rows;
    const catMap = new Map();
    for (const r of catRows) catMap.set(r.name, r.id);

    // Migrate clips
    for (const clip of clips) {
      const catId = catMap.get(clip.category) || catMap.get('Uncategorized');

      await client.query(
        `INSERT INTO clips (id, image, comment, category_id, tags, ai_summary, url, status, timestamp)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         ON CONFLICT (id) DO NOTHING`,
        [
          clip.id,
          clip.image || null,
          clip.comment || '',
          catId,
          clip.tags || [],
          clip.aiSummary || null,
          clip.url || null,
          clip.status || 'parked',
          clip.timestamp,
        ]
      );

      // Migrate thread comments
      if (clip.comments && clip.comments.length > 0) {
        for (const c of clip.comments) {
          await client.query(
            'INSERT INTO clip_comments (clip_id, text, ts) VALUES ($1, $2, $3)',
            [clip.id, c.text, c.ts]
          );
        }
      }
    }

    await client.query('COMMIT');
    await refreshCategoryCache();
    console.log(`[Sciurus DB] Migrated ${clips.length} clips and ${categories.length} categories`);
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[Sciurus DB] Migration failed:', err.message);
    return false;
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = {
  init,
  close,
  isReady,
  // Clips
  getClips,
  getClip,
  saveClip,
  updateClip,
  deleteClip,
  // Categories
  getCategories,
  getCategoryId,
  saveCategory,
  deleteCategory,
  refreshCategoryCache,
  // Projects
  getProjects,
  getProject,
  createProject,
  updateProject,
  deleteProject,
  // Comments
  addComment,
  deleteComment,
  // Settings
  getSettings,
  getAllSettings,
  saveSetting,
  // Migration
  migrateFromStore,
};

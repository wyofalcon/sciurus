// src/rules.js — Rule-based categorization engine
// Priority chain: user selection > repo_path auto-match > window rules > AI fallback

const db = require('./db');

/**
 * Auto-match a project by checking if the window title contains a known repo folder name.
 * Leverages the existing projects.repo_path column — no manual rules needed.
 *
 * @param {string|null} windowTitle
 * @returns {Promise<number|null>} project ID or null
 */
async function autoMatchProject(windowTitle) {
  if (!windowTitle) return null;
  const projects = await db.getProjects();
  const titleLower = windowTitle.toLowerCase().replace(/\\/g, '/');

  for (const p of projects) {
    if (!p.repo_path) continue;
    const repoNorm = p.repo_path.toLowerCase().replace(/\\/g, '/');
    const folderName = repoNorm.split('/').filter(Boolean).pop();
    if (folderName && titleLower.includes(folderName)) return p.id;
  }
  return null;
}

/**
 * Evaluate window_rules table against captured metadata.
 * Rules are evaluated in priority order (highest first). First match wins per field.
 *
 * @param {string|null} windowTitle
 * @param {string|null} processName
 * @returns {Promise<{ categoryId: number|null, projectId: number|null }>}
 */
async function evaluateRules(windowTitle, processName) {
  const rules = await db.getWindowRules();
  let categoryId = null;
  let projectId = null;

  for (const rule of rules) {
    const target =
      rule.match_field === 'process_name' ? processName :
      rule.match_field === 'both' ? `${windowTitle || ''} ${processName || ''}` :
      windowTitle;

    if (!target) continue;

    let matched = false;
    if (rule.match_type === 'contains') {
      matched = target.toLowerCase().includes(rule.pattern.toLowerCase());
    } else if (rule.match_type === 'startswith') {
      matched = target.toLowerCase().startsWith(rule.pattern.toLowerCase());
    } else if (rule.match_type === 'regex') {
      try { matched = new RegExp(rule.pattern, 'i').test(target); } catch { /* invalid regex */ }
    }

    if (matched) {
      if (!categoryId && rule.category_id) categoryId = rule.category_id;
      if (!projectId && rule.project_id) projectId = rule.project_id;
      if (categoryId && projectId) break; // both assigned, done
    }
  }

  return { categoryId, projectId };
}

/**
 * Run the full rule-based categorization pipeline.
 * Returns suggested category name and project ID (either may be null).
 *
 * @param {string|null} windowTitle
 * @param {string|null} processName
 * @returns {Promise<{ category: string|null, projectId: number|null }>}
 */
async function categorize(windowTitle, processName) {
  // 1. Auto-match project from repo_path
  const autoProject = await autoMatchProject(windowTitle);

  // 2. Evaluate explicit window rules
  const ruleResult = await evaluateRules(windowTitle, processName);

  // Resolve category name from ID if rules matched
  let category = null;
  if (ruleResult.categoryId) {
    category = await db.getCategoryName(ruleResult.categoryId);
  }

  return {
    category,
    projectId: ruleResult.projectId || autoProject || null,
  };
}

module.exports = { categorize, autoMatchProject, evaluateRules };

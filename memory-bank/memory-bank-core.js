#!/usr/bin/env node

/**
 * Memory Bank Core System
 * Persistent context management for Multi-Agent Agile Team
 *
 * Storage: ~/.memory-bank-storage/ (or STORAGE_DIR env var)
 * Subdirs: tasks/, agents/, sprints/, knowledge/, archives/
 */

import fs from 'fs/promises';
import path from 'path';
import { homedir } from 'os';
import { randomBytes } from 'crypto';

const STORAGE_DIR = process.env.STORAGE_DIR
  ? process.env.STORAGE_DIR.replace('~', homedir())
  : path.join(homedir(), '.memory-bank-storage');

/**
 * Atomic write: write to a temp file in the same directory, then rename.
 * Prevents partial reads if another process reads during write.
 */
async function atomicWriteFile(filePath, data) {
  const dir = path.dirname(filePath);
  const tmpFile = path.join(dir, `.tmp-${randomBytes(6).toString('hex')}`);
  try {
    await fs.writeFile(tmpFile, data);
    // rename is atomic on the same filesystem
    await fs.rename(tmpFile, filePath);
  } catch (err) {
    // Clean up temp file on failure
    try { await fs.unlink(tmpFile); } catch {}
    throw err;
  }
}

class MemoryBank {
  constructor(storageDir = STORAGE_DIR) {
    this.storageDir = storageDir;
  }

  async init() {
    for (const sub of ['tasks', 'agents', 'sprints', 'knowledge', 'archives', 'artifacts']) {
      await fs.mkdir(path.join(this.storageDir, sub), { recursive: true });
    }
  }

  // ── tasks ────────────────────────────────────────────────────────────────

  async storeTask(taskId, taskData) {
    await this.init();
    const taskPath = path.join(this.storageDir, 'tasks', `${taskId}.json`);
    const existing = await this.getTask(taskId);
    const record = {
      id: taskId,
      ...taskData,
      _meta: {
        created_at: existing?._meta?.created_at ?? new Date().toISOString(),
        updated_at: new Date().toISOString(),
        version: (existing?._meta?.version ?? 0) + 1,
      },
    };
    await atomicWriteFile(taskPath, JSON.stringify(record, null, 2));
    return record;
  }

  async getTask(taskId) {
    try {
      const data = await fs.readFile(
        path.join(this.storageDir, 'tasks', `${taskId}.json`),
        'utf-8'
      );
      return JSON.parse(data);
    } catch {
      return null;
    }
  }

  async updateTask(taskId, updates) {
    const existing = await this.getTask(taskId);
    if (!existing) throw new Error(`Task ${taskId} not found`);
    return this.storeTask(taskId, { ...existing, ...updates });
  }

  async getSprintTasks(sprintId) {
    await this.init();
    const dir = path.join(this.storageDir, 'tasks');
    const files = await fs.readdir(dir);
    const tasks = [];
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      const t = await this.getTask(path.basename(f, '.json'));
      if (t?.sprint_id === sprintId) tasks.push(t);
    }
    return tasks;
  }

  async listTasks(filter = {}) {
    await this.init();
    const dir = path.join(this.storageDir, 'tasks');
    const files = await fs.readdir(dir);
    const tasks = [];
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      const t = await this.getTask(path.basename(f, '.json'));
      if (!t) continue;
      if (filter.agent && t.assigned_to !== filter.agent) continue;
      if (filter.status && t.status !== filter.status) continue;
      if (filter.sprint_id && t.sprint_id !== filter.sprint_id) continue;
      tasks.push(t);
    }
    return tasks.sort((a, b) =>
      new Date(b._meta.updated_at) - new Date(a._meta.updated_at)
    );
  }

  // ── agents ───────────────────────────────────────────────────────────────

  async storeAgentState(agentId, state) {
    await this.init();
    const record = {
      agent_id: agentId,
      state,
      _meta: { last_activity: new Date().toISOString() },
    };
    await atomicWriteFile(
      path.join(this.storageDir, 'agents', `${agentId}.json`),
      JSON.stringify(record, null, 2)
    );
    return record;
  }

  async getAgentState(agentId) {
    try {
      const data = await fs.readFile(
        path.join(this.storageDir, 'agents', `${agentId}.json`),
        'utf-8'
      );
      return JSON.parse(data);
    } catch {
      return null;
    }
  }

  async getActiveAgents() {
    await this.init();
    const dir = path.join(this.storageDir, 'agents');
    const files = await fs.readdir(dir);
    const agents = [];
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      const a = await this.getAgentState(path.basename(f, '.json'));
      if (a) agents.push(a);
    }
    return agents;
  }

  // ── sprints ──────────────────────────────────────────────────────────────

  async createSprint(sprintData) {
    await this.init();
    const sprintId = sprintData.id ?? `sprint-${Date.now()}`;
    const sprint = {
      id: sprintId,
      status: 'planning',
      tasks: [],
      ...sprintData,
      _meta: {
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
    };
    await atomicWriteFile(
      path.join(this.storageDir, 'sprints', `${sprintId}.json`),
      JSON.stringify(sprint, null, 2)
    );
    return sprint;
  }

  async getSprint(sprintId) {
    try {
      const data = await fs.readFile(
        path.join(this.storageDir, 'sprints', `${sprintId}.json`),
        'utf-8'
      );
      return JSON.parse(data);
    } catch {
      return null;
    }
  }

  async updateSprint(sprintId, updates) {
    const existing = await this.getSprint(sprintId);
    if (!existing) throw new Error(`Sprint ${sprintId} not found`);
    const updated = {
      ...existing,
      ...updates,
      _meta: { ...existing._meta, updated_at: new Date().toISOString() },
    };
    await atomicWriteFile(
      path.join(this.storageDir, 'sprints', `${sprintId}.json`),
      JSON.stringify(updated, null, 2)
    );
    return updated;
  }

  async getActiveSprint() {
    await this.init();
    const dir = path.join(this.storageDir, 'sprints');
    const files = await fs.readdir(dir);
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      const s = await this.getSprint(path.basename(f, '.json'));
      if (s?.status === 'active') return s;
    }
    return null;
  }

  async listSprints() {
    await this.init();
    const dir = path.join(this.storageDir, 'sprints');
    const files = await fs.readdir(dir);
    const sprints = [];
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      const s = await this.getSprint(path.basename(f, '.json'));
      if (s) sprints.push(s);
    }
    return sprints.sort((a, b) =>
      new Date(b._meta.created_at) - new Date(a._meta.created_at)
    );
  }

  // ── knowledge base ───────────────────────────────────────────────────────

  async storeKnowledge(category, key, content) {
    await this.init();
    const catDir = path.join(this.storageDir, 'knowledge', category);
    await fs.mkdir(catDir, { recursive: true });
    const meta = {
      category,
      key,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
    await atomicWriteFile(path.join(catDir, `${key}.md`), content);
    await atomicWriteFile(
      path.join(catDir, `${key}.meta.json`),
      JSON.stringify(meta, null, 2)
    );
    return { ...meta, content };
  }

  async getKnowledge(category, key) {
    try {
      const catDir = path.join(this.storageDir, 'knowledge', category);
      const content = await fs.readFile(path.join(catDir, `${key}.md`), 'utf-8');
      const meta = JSON.parse(
        await fs.readFile(path.join(catDir, `${key}.meta.json`), 'utf-8')
      );
      return { ...meta, content };
    } catch {
      return null;
    }
  }

  async searchKnowledge(query) {
    await this.init();
    const knowledgeDir = path.join(this.storageDir, 'knowledge');
    const results = [];
    try {
      const categories = await fs.readdir(knowledgeDir);
      for (const cat of categories) {
        const catDir = path.join(knowledgeDir, cat);
        const stat = await fs.stat(catDir).catch(() => null);
        if (!stat?.isDirectory()) continue;
        const files = await fs.readdir(catDir);
        for (const f of files) {
          if (!f.endsWith('.md')) continue;
          const key = path.basename(f, '.md');
          const article = await this.getKnowledge(cat, key);
          if (article?.content.toLowerCase().includes(query.toLowerCase())) {
            results.push(article);
          }
        }
      }
    } catch {}
    return results;
  }

  // ── context compression ──────────────────────────────────────────────────

  async getCompressedContext(taskId) {
    const task = await this.getTask(taskId);
    if (!task) return null;
    return {
      task_id: task.id,
      title: task.title,
      status: task.status,
      assigned_to: task.assigned_to,
      priority: task.priority,
      key_reqs: (task.requirements ?? []).slice(0, 3),
      dependencies: task.dependencies ?? [],
      last_update: task._meta.updated_at,
    };
  }

  // ── reporting ────────────────────────────────────────────────────────────

  async generateSprintReport(sprintId) {
    const sprint = await this.getSprint(sprintId);
    const tasks = await this.getSprintTasks(sprintId);

    if (!sprint) return { error: `Sprint ${sprintId} not found` };

    const done = tasks.filter((t) => t.status === 'done').length;
    const inProgress = tasks.filter((t) => t.status === 'in_progress').length;
    const todo = tasks.filter((t) => t.status === 'todo').length;

    const byAgent = tasks.reduce((acc, t) => {
      const a = t.assigned_to ?? 'unassigned';
      if (!acc[a]) acc[a] = { total: 0, done: 0, in_progress: 0 };
      acc[a].total++;
      if (t.status === 'done') acc[a].done++;
      if (t.status === 'in_progress') acc[a].in_progress++;
      return acc;
    }, {});

    return {
      sprint_id: sprintId,
      sprint_name: sprint.name,
      goal: sprint.goal,
      status: sprint.status,
      total_tasks: tasks.length,
      done,
      in_progress: inProgress,
      todo,
      completion_rate: tasks.length
        ? ((done / tasks.length) * 100).toFixed(1) + '%'
        : '0%',
      by_agent: byAgent,
    };
  }

  // ── velocity tracking ────────────────────────────────────────────────────

  /**
   * Calculate velocity for a sprint (story_points of done tasks, or task count as fallback)
   */
  async getSprintVelocity(sprintId) {
    const tasks = await this.getSprintTasks(sprintId);
    const done = tasks.filter((t) => t.status === 'done');
    const points = done.reduce((sum, t) => sum + (t.story_points ?? 1), 0);
    return { sprint_id: sprintId, completed_tasks: done.length, velocity_points: points };
  }

  /**
   * Get velocity trend across last N completed/archived sprints
   */
  async getVelocityTrend(n = 5) {
    const sprints = await this.listSprints();
    const completed = sprints
      .filter((s) => ['completed', 'archived'].includes(s.status))
      .slice(0, n);

    const trend = [];
    for (const s of completed) {
      const v = await this.getSprintVelocity(s.id);
      trend.push({
        sprint_id: s.id,
        sprint_name: s.name,
        velocity: v.velocity_points,
        completed_tasks: v.completed_tasks,
        end_date: s.end_date ?? s._meta.updated_at,
      });
    }

    if (trend.length < 2) return { trend, average: trend[0]?.velocity ?? 0, direction: 'insufficient_data' };

    const avg = Math.round(trend.reduce((s, t) => s + t.velocity, 0) / trend.length);
    const latest = trend[0]?.velocity ?? 0;
    const previous = trend[1]?.velocity ?? 0;
    const direction = latest > previous ? 'improving' : latest < previous ? 'declining' : 'stable';

    return { trend, average: avg, direction, latest, previous };
  }

  // ── product backlog ──────────────────────────────────────────────────────

  async addBacklogItem(itemData) {
    await this.init();
    const backlogDir = path.join(this.storageDir, 'backlog');
    await fs.mkdir(backlogDir, { recursive: true });
    const itemId = itemData.id ?? `BLI-${Date.now()}`;
    const item = {
      id: itemId,
      status: 'backlog',
      story_points: null,
      priority: 'medium',
      ...itemData,
      _meta: {
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
    };
    await atomicWriteFile(
      path.join(backlogDir, `${itemId}.json`),
      JSON.stringify(item, null, 2)
    );
    return item;
  }

  async getBacklog(filter = {}) {
    await this.init();
    const backlogDir = path.join(this.storageDir, 'backlog');
    await fs.mkdir(backlogDir, { recursive: true });
    const files = await fs.readdir(backlogDir);
    const items = [];
    for (const f of files) {
      if (!f.endsWith('.json')) continue;
      try {
        const data = await fs.readFile(path.join(backlogDir, f), 'utf-8');
        const item = JSON.parse(data);
        if (filter.priority && item.priority !== filter.priority) continue;
        if (filter.status && item.status !== filter.status) continue;
        items.push(item);
      } catch {}
    }
    // Sort by priority weight then creation date
    const priorityOrder = { critical: 0, high: 1, medium: 2, low: 3 };
    return items.sort((a, b) =>
      (priorityOrder[a.priority] ?? 2) - (priorityOrder[b.priority] ?? 2) ||
      new Date(a._meta.created_at) - new Date(b._meta.created_at)
    );
  }

  async promoteToSprint(itemId, sprintId) {
    const backlogDir = path.join(this.storageDir, 'backlog');
    const itemPath = path.join(backlogDir, `${itemId}.json`);
    try {
      const data = await fs.readFile(itemPath, 'utf-8');
      const item = JSON.parse(data);
      // Create as a task in the sprint
      await this.storeTask(itemId, {
        ...item,
        sprint_id: sprintId,
        status: 'todo',
        _meta: { ...item._meta, updated_at: new Date().toISOString() },
      });
      // Mark backlog item as promoted
      const updated = { ...item, status: 'in_sprint', sprint_id: sprintId, _meta: { ...item._meta, updated_at: new Date().toISOString() } };
      await atomicWriteFile(itemPath, JSON.stringify(updated, null, 2));
      return { promoted: itemId, sprint_id: sprintId };
    } catch (err) {
      throw new Error(`Backlog item ${itemId} not found: ${err.message}`);
    }
  }

  // ── artifacts (inter-agent handoff) ─────────────────────────────────────

  /**
   * Store an agent's output artifact for a task.
   * agentRole: e.g. "ba", "architect", "security", "dev", "qa", "devops"
   */
  async storeArtifact(taskId, agentRole, content, meta = {}) {
    await this.init();
    const taskDir = path.join(this.storageDir, 'artifacts', taskId);
    await fs.mkdir(taskDir, { recursive: true });
    const record = {
      task_id: taskId,
      agent_role: agentRole,
      content,
      status: meta.status ?? 'pass',
      summary: meta.summary ?? '',
      next_action: meta.next_action ?? '',
      _meta: { stored_at: new Date().toISOString() },
    };
    await atomicWriteFile(
      path.join(taskDir, `${agentRole}.json`),
      JSON.stringify(record, null, 2)
    );
    return record;
  }

  async getArtifact(taskId, agentRole) {
    try {
      const data = await fs.readFile(
        path.join(this.storageDir, 'artifacts', taskId, `${agentRole}.json`),
        'utf-8'
      );
      return JSON.parse(data);
    } catch {
      return null;
    }
  }

  async listArtifacts(taskId) {
    try {
      const taskDir = path.join(this.storageDir, 'artifacts', taskId);
      const files = await fs.readdir(taskDir);
      const artifacts = [];
      for (const f of files) {
        if (!f.endsWith('.json')) continue;
        const data = await fs.readFile(path.join(taskDir, f), 'utf-8');
        const a = JSON.parse(data);
        // Return summary only (not full content) to save tokens
        artifacts.push({
          agent_role: a.agent_role,
          status: a.status,
          summary: a.summary,
          next_action: a.next_action,
          stored_at: a._meta.stored_at,
        });
      }
      return artifacts.sort((a, b) => new Date(a.stored_at) - new Date(b.stored_at));
    } catch {
      return [];
    }
  }

  // ── revisions ────────────────────────────────────────────────────────────

  /**
   * Create a revision request for a task — stores what needs to change and why.
   */
  async createRevision(originalTaskId, feedback) {
    await this.init();
    const revisionId = `${originalTaskId}-REV-${Date.now()}`;
    const record = {
      revision_id: revisionId,
      original_task_id: originalTaskId,
      feedback_for_agent: feedback.feedback_for_agent,
      keep: feedback.keep ?? [],
      change: feedback.change ?? [],
      reason: feedback.reason ?? '',
      requested_by: 'orchestrator',
      status: 'pending',
      _meta: { created_at: new Date().toISOString() },
    };
    await atomicWriteFile(
      path.join(this.storageDir, 'tasks', `${revisionId}.json`),
      JSON.stringify(record, null, 2)
    );
    return record;
  }

  // ── archive ──────────────────────────────────────────────────────────────

  async archiveSprint(sprintId) {
    const sprint = await this.getSprint(sprintId);
    const tasks = await this.getSprintTasks(sprintId);
    const archDir = path.join(this.storageDir, 'archives', sprintId);
    await fs.mkdir(archDir, { recursive: true });
    await atomicWriteFile(
      path.join(archDir, 'sprint.json'),
      JSON.stringify(sprint, null, 2)
    );
    await atomicWriteFile(
      path.join(archDir, 'tasks.json'),
      JSON.stringify(tasks, null, 2)
    );
    await this.updateSprint(sprintId, { status: 'archived' });
    return { archived_sprint: sprintId, archived_tasks: tasks.length, archive_path: archDir };
  }
}

export default new MemoryBank();

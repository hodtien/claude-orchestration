#!/usr/bin/env node

/**
 * Memory Bank Core System
 * Persistent context management for Multi-Agent Agile Team
 * 
 * Features:
 * - Task history tracking
 * - Context preservation across sessions
 * - Shared knowledge base
 * - Agent state management
 * - Token-efficient storage
 */

import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

class MemoryBank {
  constructor(storageDir = path.join(__dirname, '.memory-storage')) {
    this.storageDir = storageDir;
    this.ensureStorageDir();
  }

  async ensureStorageDir() {
    try {
      await fs.mkdir(this.storageDir, { recursive: true });
      await fs.mkdir(path.join(this.storageDir, 'tasks'), { recursive: true });
      await fs.mkdir(path.join(this.storageDir, 'agents'), { recursive: true });
      await fs.mkdir(path.join(this.storageDir, 'sprints'), { recursive: true });
      await fs.mkdir(path.join(this.storageDir, 'knowledge'), { recursive: true });
    } catch (err) {
      console.error('Failed to create storage directory:', err);
    }
  }

  // ============================================
  // TASK MEMORY MANAGEMENT
  // ============================================

  /**
   * Store task with full context
   */
  async storeTask(taskId, taskData) {
    const taskPath = path.join(this.storageDir, 'tasks', `${taskId}.json`);
    const taskRecord = {
      id: taskId,
      timestamp: new Date().toISOString(),
      ...taskData,
      _meta: {
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        version: 1
      }
    };

    await fs.writeFile(taskPath, JSON.stringify(taskRecord, null, 2));
    return taskRecord;
  }

  /**
   * Retrieve task from memory
   */
  async getTask(taskId) {
    try {
      const taskPath = path.join(this.storageDir, 'tasks', `${taskId}.json`);
      const data = await fs.readFile(taskPath, 'utf-8');
      return JSON.parse(data);
    } catch (err) {
      return null;
    }
  }

  /**
   * Update existing task
   */
  async updateTask(taskId, updates) {
    const existing = await this.getTask(taskId);
    if (!existing) {
      throw new Error(`Task ${taskId} not found`);
    }

    const updated = {
      ...existing,
      ...updates,
      _meta: {
        ...existing._meta,
        updated_at: new Date().toISOString(),
        version: (existing._meta.version || 1) + 1
      }
    };

    await this.storeTask(taskId, updated);
    return updated;
  }

  /**
   * Get all tasks for a sprint
   */
  async getSprintTasks(sprintId) {
    const tasksDir = path.join(this.storageDir, 'tasks');
    const files = await fs.readdir(tasksDir);
    const tasks = [];

    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const task = await this.getTask(path.basename(file, '.json'));
      if (task && task.sprint_id === sprintId) {
        tasks.push(task);
      }
    }

    return tasks;
  }

  // ============================================
  // AGENT STATE MANAGEMENT
  // ============================================

  /**
   * Store agent's current state and context
   */
  async storeAgentState(agentId, state) {
    const statePath = path.join(this.storageDir, 'agents', `${agentId}.json`);
    const stateRecord = {
      agent_id: agentId,
      timestamp: new Date().toISOString(),
      state,
      _meta: {
        last_activity: new Date().toISOString()
      }
    };

    await fs.writeFile(statePath, JSON.stringify(stateRecord, null, 2));
    return stateRecord;
  }

  /**
   * Get agent's current state
   */
  async getAgentState(agentId) {
    try {
      const statePath = path.join(this.storageDir, 'agents', `${agentId}.json`);
      const data = await fs.readFile(statePath, 'utf-8');
      return JSON.parse(data);
    } catch (err) {
      return null;
    }
  }

  /**
   * Get all active agents
   */
  async getActiveAgents() {
    const agentsDir = path.join(this.storageDir, 'agents');
    const files = await fs.readdir(agentsDir);
    const agents = [];

    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const agent = await this.getAgentState(path.basename(file, '.json'));
      if (agent) {
        agents.push(agent);
      }
    }

    return agents;
  }

  // ============================================
  // SPRINT MANAGEMENT
  // ============================================

  /**
   * Create new sprint
   */
  async createSprint(sprintData) {
    const sprintId = `sprint-${Date.now()}`;
    const sprintPath = path.join(this.storageDir, 'sprints', `${sprintId}.json`);
    
    const sprint = {
      id: sprintId,
      ...sprintData,
      created_at: new Date().toISOString(),
      status: 'planning',
      tasks: [],
      _meta: {
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      }
    };

    await fs.writeFile(sprintPath, JSON.stringify(sprint, null, 2));
    return sprint;
  }

  /**
   * Get sprint details
   */
  async getSprint(sprintId) {
    try {
      const sprintPath = path.join(this.storageDir, 'sprints', `${sprintId}.json`);
      const data = await fs.readFile(sprintPath, 'utf-8');
      return JSON.parse(data);
    } catch (err) {
      return null;
    }
  }

  /**
   * Update sprint
   */
  async updateSprint(sprintId, updates) {
    const existing = await this.getSprint(sprintId);
    if (!existing) {
      throw new Error(`Sprint ${sprintId} not found`);
    }

    const updated = {
      ...existing,
      ...updates,
      _meta: {
        ...existing._meta,
        updated_at: new Date().toISOString()
      }
    };

    const sprintPath = path.join(this.storageDir, 'sprints', `${sprintId}.json`);
    await fs.writeFile(sprintPath, JSON.stringify(updated, null, 2));
    return updated;
  }

  /**
   * Get current active sprint
   */
  async getActiveSprint() {
    const sprintsDir = path.join(this.storageDir, 'sprints');
    const files = await fs.readdir(sprintsDir);

    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const sprint = await this.getSprint(path.basename(file, '.json'));
      if (sprint && sprint.status === 'active') {
        return sprint;
      }
    }

    return null;
  }

  // ============================================
  // KNOWLEDGE BASE MANAGEMENT
  // ============================================

  /**
   * Store knowledge article
   */
  async storeKnowledge(category, key, content) {
    const categoryDir = path.join(this.storageDir, 'knowledge', category);
    await fs.mkdir(categoryDir, { recursive: true });

    const knowledgePath = path.join(categoryDir, `${key}.md`);
    const article = {
      category,
      key,
      content,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };

    await fs.writeFile(knowledgePath, content);
    
    // Store metadata
    const metaPath = path.join(categoryDir, `${key}.meta.json`);
    await fs.writeFile(metaPath, JSON.stringify(article, null, 2));

    return article;
  }

  /**
   * Retrieve knowledge
   */
  async getKnowledge(category, key) {
    try {
      const knowledgePath = path.join(this.storageDir, 'knowledge', category, `${key}.md`);
      const metaPath = path.join(this.storageDir, 'knowledge', category, `${key}.meta.json`);
      
      const content = await fs.readFile(knowledgePath, 'utf-8');
      const meta = JSON.parse(await fs.readFile(metaPath, 'utf-8'));

      return {
        ...meta,
        content
      };
    } catch (err) {
      return null;
    }
  }

  /**
   * Search knowledge base
   */
  async searchKnowledge(category, query) {
    const categoryDir = path.join(this.storageDir, 'knowledge', category);
    try {
      const files = await fs.readdir(categoryDir);
      const results = [];

      for (const file of files) {
        if (!file.endsWith('.md')) continue;
        const key = path.basename(file, '.md');
        const article = await this.getKnowledge(category, key);
        
        if (article && article.content.toLowerCase().includes(query.toLowerCase())) {
          results.push(article);
        }
      }

      return results;
    } catch (err) {
      return [];
    }
  }

  // ============================================
  // CONTEXT COMPRESSION
  // ============================================

  /**
   * Generate compressed summary for token efficiency
   */
  async getCompressedContext(taskId) {
    const task = await this.getTask(taskId);
    if (!task) return null;

    // Compress context to essential information
    return {
      task_id: task.id,
      title: task.title,
      status: task.status,
      assigned_to: task.assigned_to,
      priority: task.priority,
      key_points: task.requirements?.slice(0, 3) || [],
      dependencies: task.dependencies || [],
      last_update: task._meta.updated_at
    };
  }

  /**
   * Get agent's working context (last 5 tasks)
   */
  async getAgentWorkingContext(agentId) {
    const tasksDir = path.join(this.storageDir, 'tasks');
    const files = await fs.readdir(tasksDir);
    const agentTasks = [];

    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const task = await this.getTask(path.basename(file, '.json'));
      if (task && task.assigned_to === agentId) {
        agentTasks.push(task);
      }
    }

    // Sort by update time, get last 5
    return agentTasks
      .sort((a, b) => new Date(b._meta.updated_at) - new Date(a._meta.updated_at))
      .slice(0, 5)
      .map(task => ({
        id: task.id,
        title: task.title,
        status: task.status,
        last_update: task._meta.updated_at
      }));
  }

  // ============================================
  // REPORTING & ANALYTICS
  // ============================================

  /**
   * Generate sprint report
   */
  async generateSprintReport(sprintId) {
    const sprint = await this.getSprint(sprintId);
    const tasks = await this.getSprintTasks(sprintId);

    const completed = tasks.filter(t => t.status === 'done').length;
    const inProgress = tasks.filter(t => t.status === 'in_progress').length;
    const todo = tasks.filter(t => t.status === 'todo').length;

    return {
      sprint_id: sprintId,
      sprint_name: sprint.name,
      total_tasks: tasks.length,
      completed,
      in_progress: inProgress,
      todo,
      completion_rate: (completed / tasks.length * 100).toFixed(2) + '%',
      tasks_by_agent: this.groupTasksByAgent(tasks)
    };
  }

  groupTasksByAgent(tasks) {
    return tasks.reduce((acc, task) => {
      const agent = task.assigned_to || 'unassigned';
      if (!acc[agent]) {
        acc[agent] = { total: 0, completed: 0, in_progress: 0 };
      }
      acc[agent].total++;
      if (task.status === 'done') acc[agent].completed++;
      if (task.status === 'in_progress') acc[agent].in_progress++;
      return acc;
    }, {});
  }

  // ============================================
  // CLEANUP & MAINTENANCE
  // ============================================

  /**
   * Archive completed sprint
   */
  async archiveSprint(sprintId) {
    const sprint = await this.getSprint(sprintId);
    const tasks = await this.getSprintTasks(sprintId);

    const archiveDir = path.join(this.storageDir, 'archives', sprintId);
    await fs.mkdir(archiveDir, { recursive: true });

    // Archive sprint data
    await fs.writeFile(
      path.join(archiveDir, 'sprint.json'),
      JSON.stringify(sprint, null, 2)
    );

    // Archive tasks
    await fs.writeFile(
      path.join(archiveDir, 'tasks.json'),
      JSON.stringify(tasks, null, 2)
    );

    return {
      archived_sprint: sprintId,
      archived_tasks: tasks.length,
      archive_path: archiveDir
    };
  }
}

// Export singleton instance
export default new MemoryBank();

// CLI interface for testing
if (import.meta.url === `file://${process.argv[1]}`) {
  const bank = new MemoryBank();

  const testMemoryBank = async () => {
    console.log('🧠 Memory Bank System - Testing\n');

    // Test 1: Create sprint
    console.log('1️⃣ Creating sprint...');
    const sprint = await bank.createSprint({
      name: 'Sprint 1 - MVP Features',
      start_date: '2026-04-15',
      end_date: '2026-04-29',
      goal: 'Implement core authentication and user management'
    });
    console.log('✅ Sprint created:', sprint.id);

    // Test 2: Store task
    console.log('\n2️⃣ Creating tasks...');
    const task1 = await bank.storeTask('TASK-001', {
      title: 'Implement JWT authentication',
      sprint_id: sprint.id,
      assigned_to: 'copilot-agent',
      status: 'todo',
      priority: 'high',
      requirements: [
        'OAuth 2.0 flow',
        'JWT token generation',
        'Refresh token mechanism'
      ]
    });
    console.log('✅ Task created:', task1.id);

    // Test 3: Store agent state
    console.log('\n3️⃣ Storing agent state...');
    await bank.storeAgentState('copilot-agent', {
      current_tasks: ['TASK-001'],
      status: 'working',
      context: 'Implementing authentication module'
    });
    console.log('✅ Agent state stored');

    // Test 4: Store knowledge
    console.log('\n4️⃣ Storing knowledge...');
    await bank.storeKnowledge(
      'architecture',
      'auth-design',
      '# Authentication Design\n\n## OAuth 2.0 Flow\n- Authorization Code Flow\n- PKCE for mobile\n'
    );
    console.log('✅ Knowledge stored');

    // Test 5: Get compressed context
    console.log('\n5️⃣ Getting compressed context...');
    const context = await bank.getCompressedContext('TASK-001');
    console.log('✅ Compressed context:', context);

    // Test 6: Generate report
    console.log('\n6️⃣ Generating sprint report...');
    const report = await bank.generateSprintReport(sprint.id);
    console.log('✅ Sprint report:', report);

    console.log('\n✨ Memory Bank System is working correctly!');
  };

  testMemoryBank().catch(console.error);
}

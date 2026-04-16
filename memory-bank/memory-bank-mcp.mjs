#!/usr/bin/env node
/**
 * Memory Bank MCP Server
 * Exposes memory-bank-core.js as MCP tools for Claude.
 *
 * Register with:
 *   claude mcp add memory-bank node ~/claude-orchestration/memory-bank/memory-bank-mcp.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import memoryBank from "./memory-bank-core.js";

const server = new Server(
  { name: "memory-bank", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// ── tool definitions ─────────────────────────────────────────────────────────

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "store_task",
      description: "Store or update a task in the memory bank (persistent across sessions)",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string", description: "e.g. TASK-DEV-001" },
          taskData: {
            type: "object",
            description: "Task fields: title, status, assigned_to, priority, sprint_id, requirements[], dependencies[]",
          },
        },
        required: ["taskId", "taskData"],
      },
    },
    {
      name: "get_task",
      description: "Retrieve a task from the memory bank by ID",
      inputSchema: {
        type: "object",
        properties: { taskId: { type: "string" } },
        required: ["taskId"],
      },
    },
    {
      name: "update_task",
      description: "Update specific fields of an existing task",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string" },
          updates: { type: "object" },
        },
        required: ["taskId", "updates"],
      },
    },
    {
      name: "list_tasks",
      description: "List tasks with optional filters (agent, status, sprint_id)",
      inputSchema: {
        type: "object",
        properties: {
          agent: { type: "string" },
          status: { type: "string", enum: ["todo", "in_progress", "done", "blocked"] },
          sprint_id: { type: "string" },
        },
      },
    },
    {
      name: "store_agent_state",
      description: "Store an agent's current working state",
      inputSchema: {
        type: "object",
        properties: {
          agentId: { type: "string" },
          state: { type: "object" },
        },
        required: ["agentId", "state"],
      },
    },
    {
      name: "get_agent_state",
      description: "Get an agent's stored state",
      inputSchema: {
        type: "object",
        properties: { agentId: { type: "string" } },
        required: ["agentId"],
      },
    },
    {
      name: "get_active_agents",
      description: "List all agents with stored state",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "create_sprint",
      description: "Create a new sprint",
      inputSchema: {
        type: "object",
        properties: {
          sprintData: {
            type: "object",
            description: "Sprint fields: name, goal, start_date, end_date (id auto-generated if omitted)",
          },
        },
        required: ["sprintData"],
      },
    },
    {
      name: "get_sprint",
      description: "Get sprint details by ID",
      inputSchema: {
        type: "object",
        properties: { sprintId: { type: "string" } },
        required: ["sprintId"],
      },
    },
    {
      name: "update_sprint",
      description: "Update sprint fields (e.g. status: active/completed)",
      inputSchema: {
        type: "object",
        properties: {
          sprintId: { type: "string" },
          updates: { type: "object" },
        },
        required: ["sprintId", "updates"],
      },
    },
    {
      name: "get_active_sprint",
      description: "Get the current active sprint",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "list_sprints",
      description: "List all sprints (newest first)",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "get_sprint_report",
      description: "Generate a sprint completion report with metrics",
      inputSchema: {
        type: "object",
        properties: { sprintId: { type: "string" } },
        required: ["sprintId"],
      },
    },
    {
      name: "archive_sprint",
      description: "Archive a completed sprint and its tasks",
      inputSchema: {
        type: "object",
        properties: { sprintId: { type: "string" } },
        required: ["sprintId"],
      },
    },
    {
      name: "store_knowledge",
      description: "Store a knowledge article (markdown) in the shared knowledge base",
      inputSchema: {
        type: "object",
        properties: {
          category: { type: "string", description: "e.g. architecture, security, decisions" },
          key: { type: "string", description: "Article slug/identifier" },
          content: { type: "string", description: "Markdown content" },
        },
        required: ["category", "key", "content"],
      },
    },
    {
      name: "get_knowledge",
      description: "Retrieve a knowledge article",
      inputSchema: {
        type: "object",
        properties: {
          category: { type: "string" },
          key: { type: "string" },
        },
        required: ["category", "key"],
      },
    },
    {
      name: "search_knowledge",
      description: "Search the knowledge base by keyword",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string" } },
        required: ["query"],
      },
    },
    {
      name: "get_compressed_context",
      description: "Get a token-efficient summary of a task (use instead of full task for context injection)",
      inputSchema: {
        type: "object",
        properties: { taskId: { type: "string" } },
        required: ["taskId"],
      },
    },
    {
      name: "get_velocity_trend",
      description: "Get velocity trend across last N completed sprints — shows improving/declining/stable",
      inputSchema: {
        type: "object",
        properties: {
          n: { type: "number", description: "Number of sprints to look back (default: 5)" },
        },
      },
    },
    {
      name: "get_sprint_velocity",
      description: "Get velocity (story points completed) for a specific sprint",
      inputSchema: {
        type: "object",
        properties: { sprintId: { type: "string" } },
        required: ["sprintId"],
      },
    },
    {
      name: "add_backlog_item",
      description: "Add an item to the product backlog (pre-sprint)",
      inputSchema: {
        type: "object",
        properties: {
          itemData: {
            type: "object",
            description: "Item fields: title, description, priority (critical/high/medium/low), story_points, type (feature/bug/tech-debt)",
          },
        },
        required: ["itemData"],
      },
    },
    {
      name: "get_backlog",
      description: "Get product backlog items sorted by priority",
      inputSchema: {
        type: "object",
        properties: {
          priority: { type: "string", enum: ["critical", "high", "medium", "low"] },
          status: { type: "string", description: "backlog | in_sprint (default: backlog)" },
        },
      },
    },
    {
      name: "promote_to_sprint",
      description: "Move a backlog item into a sprint as a task",
      inputSchema: {
        type: "object",
        properties: {
          itemId: { type: "string" },
          sprintId: { type: "string" },
        },
        required: ["itemId", "sprintId"],
      },
    },
    {
      name: "store_artifact",
      description: "Store an agent's output artifact for inter-agent handoff. Call this after every agent completes work.",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string", description: "Task this artifact belongs to (e.g. TASK-DEV-001)" },
          agentRole: { type: "string", description: "Agent that produced this: ba | architect | security | dev | qa | devops" },
          content: { type: "string", description: "Full output from the agent" },
          meta: {
            type: "object",
            description: "status (pass|needs_revision|blocked), summary (1 sentence), next_action",
          },
        },
        required: ["taskId", "agentRole", "content"],
      },
    },
    {
      name: "get_artifact",
      description: "Retrieve a specific agent's artifact for a task (full content for context injection)",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string" },
          agentRole: { type: "string", description: "ba | architect | security | dev | qa | devops" },
        },
        required: ["taskId", "agentRole"],
      },
    },
    {
      name: "list_artifacts",
      description: "List all artifacts produced so far for a task (summaries only — token-efficient)",
      inputSchema: {
        type: "object",
        properties: { taskId: { type: "string" } },
        required: ["taskId"],
      },
    },
    {
      name: "create_revision",
      description: "Request a revision of an agent's output — specify what to keep, what to change, and why",
      inputSchema: {
        type: "object",
        properties: {
          originalTaskId: { type: "string" },
          feedback: {
            type: "object",
            description: "feedback_for_agent (string), keep (string[]), change (string[]), reason (string)",
          },
        },
        required: ["originalTaskId", "feedback"],
      },
    },
  ],
}));

// ── tool handlers ─────────────────────────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  try {
    let result;
    switch (name) {
      case "store_task":
        result = await memoryBank.storeTask(args.taskId, args.taskData);
        break;
      case "get_task":
        result = await memoryBank.getTask(args.taskId);
        break;
      case "update_task":
        result = await memoryBank.updateTask(args.taskId, args.updates);
        break;
      case "list_tasks":
        result = await memoryBank.listTasks(args ?? {});
        break;
      case "store_agent_state":
        result = await memoryBank.storeAgentState(args.agentId, args.state);
        break;
      case "get_agent_state":
        result = await memoryBank.getAgentState(args.agentId);
        break;
      case "get_active_agents":
        result = await memoryBank.getActiveAgents();
        break;
      case "create_sprint":
        result = await memoryBank.createSprint(args.sprintData);
        break;
      case "get_sprint":
        result = await memoryBank.getSprint(args.sprintId);
        break;
      case "update_sprint":
        result = await memoryBank.updateSprint(args.sprintId, args.updates);
        break;
      case "get_active_sprint":
        result = await memoryBank.getActiveSprint();
        break;
      case "list_sprints":
        result = await memoryBank.listSprints();
        break;
      case "get_sprint_report":
        result = await memoryBank.generateSprintReport(args.sprintId);
        break;
      case "archive_sprint":
        result = await memoryBank.archiveSprint(args.sprintId);
        break;
      case "store_knowledge":
        result = await memoryBank.storeKnowledge(args.category, args.key, args.content);
        break;
      case "get_knowledge":
        result = await memoryBank.getKnowledge(args.category, args.key);
        break;
      case "search_knowledge":
        result = await memoryBank.searchKnowledge(args.query);
        break;
      case "get_compressed_context":
        result = await memoryBank.getCompressedContext(args.taskId);
        break;
      case "get_velocity_trend":
        result = await memoryBank.getVelocityTrend(args?.n ?? 5);
        break;
      case "get_sprint_velocity":
        result = await memoryBank.getSprintVelocity(args.sprintId);
        break;
      case "add_backlog_item":
        result = await memoryBank.addBacklogItem(args.itemData);
        break;
      case "get_backlog":
        result = await memoryBank.getBacklog(args ?? {});
        break;
      case "promote_to_sprint":
        result = await memoryBank.promoteToSprint(args.itemId, args.sprintId);
        break;
      case "store_artifact":
        result = await memoryBank.storeArtifact(args.taskId, args.agentRole, args.content, args.meta ?? {});
        break;
      case "get_artifact":
        result = await memoryBank.getArtifact(args.taskId, args.agentRole);
        break;
      case "list_artifacts":
        result = await memoryBank.listArtifacts(args.taskId);
        break;
      case "create_revision":
        result = await memoryBank.createRevision(args.originalTaskId, args.feedback);
        break;
      default:
        return {
          content: [{ type: "text", text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(result ?? null, null, 2) }],
    };
  } catch (err) {
    return {
      content: [{ type: "text", text: `Error: ${err.message}` }],
      isError: true,
    };
  }
});

// ── start ─────────────────────────────────────────────────────────────────────
const transport = new StdioServerTransport();
await server.connect(transport);
console.error("Memory Bank MCP server running");

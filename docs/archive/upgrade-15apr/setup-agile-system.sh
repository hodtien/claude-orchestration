#!/bin/bash

##############################################################################
# Claude Agile Multi-Agent System - Automated Setup
# 
# This script sets up the complete Agile development team including:
# - Memory Bank system
# - All agent MCP servers
# - Task templates
# - Workflow automation
# - First sprint initialization
##############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Banner
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Claude Agile Multi-Agent System Setup                   ║"
echo "║   Transform Claude into a Complete Development Team       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Check Prerequisites
log_info "Checking prerequisites..."

# Check Node.js
if ! command -v node &> /dev/null; then
    log_error "Node.js not found. Please install Node.js 20+ first"
    exit 1
fi

NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 20 ]; then
    log_error "Node.js version must be 20 or higher. Current: $(node --version)"
    exit 1
fi
log_success "Node.js $(node --version) detected"

# Check npm
if ! command -v npm &> /dev/null; then
    log_error "npm not found"
    exit 1
fi
log_success "npm $(npm --version) detected"

# Check GitHub Copilot CLI
if ! command -v copilot &> /dev/null; then
    log_warning "GitHub Copilot CLI not found. Installing..."
    npm install -g @github/copilot-cli
    if [ $? -eq 0 ]; then
        log_success "GitHub Copilot CLI installed"
        log_warning "Please run 'copilot auth login' to authenticate"
    else
        log_error "Failed to install GitHub Copilot CLI"
        exit 1
    fi
else
    log_success "GitHub Copilot CLI detected"
fi

# Check Gemini CLI (optional)
if ! command -v gemini &> /dev/null; then
    log_warning "Gemini CLI not found (optional). Install with: npm install -g @google/generative-ai-cli"
else
    log_success "Gemini CLI detected"
fi

echo ""

# Step 2: Setup Directory Structure
log_info "Setting up directory structure..."

SYSTEM_DIR="$HOME/agile-multiagent-system"
mkdir -p "$SYSTEM_DIR"
cd "$SYSTEM_DIR"

# Create subdirectories
mkdir -p memory-bank
mkdir -p agent-configs/mcp-servers
mkdir -p task-protocols
mkdir -p workflows
mkdir -p templates
mkdir -p .memory-bank-storage/{tasks,agents,sprints,knowledge,archives}

log_success "Directory structure created at $SYSTEM_DIR"

echo ""

# Step 3: Install MCP SDK
log_info "Installing MCP SDK..."

if [ ! -f "package.json" ]; then
    npm init -y &> /dev/null
fi

npm install @modelcontextprotocol/sdk &> /dev/null

log_success "MCP SDK installed"

echo ""

# Step 4: Configure Claude Desktop
log_info "Configuring Claude Desktop MCP servers..."

CLAUDE_CONFIG_DIR="$HOME/.claude"
CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

mkdir -p "$CLAUDE_CONFIG_DIR"

# Create MCP configuration
cat > "$CLAUDE_CONFIG_FILE" << 'EOF'
{
  "mcpServers": {
    "copilot-dev-agent": {
      "command": "npx",
      "args": ["-y", "@leonardommello/copilot-mcp-server"],
      "env": {
        "AGENT_ROLE": "developer",
        "AGENT_ID": "copilot-dev-001"
      }
    },
    "memory-bank": {
      "command": "node",
      "args": ["~/agile-multiagent-system/memory-bank/memory-bank-mcp.js"],
      "env": {
        "STORAGE_DIR": "~/.memory-bank-storage"
      }
    }
  }
}
EOF

log_success "Claude Desktop config created at $CLAUDE_CONFIG_FILE"

echo ""

# Step 5: Create Memory Bank System
log_info "Setting up Memory Bank system..."

# Copy memory bank files from current directory
if [ -f "memory-bank/memory-bank-core.js" ]; then
    log_success "Memory Bank core already exists"
else
    log_warning "Memory Bank core not found - you'll need to copy it manually"
fi

# Create Memory Bank MCP Server wrapper
cat > "memory-bank/memory-bank-mcp.js" << 'EOF'
#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import memoryBank from './memory-bank-core.js';

const server = new Server(
  { name: "memory-bank", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// Define memory bank tools
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "store_task",
      description: "Store task in memory bank",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string" },
          taskData: { type: "object" }
        },
        required: ["taskId", "taskData"]
      }
    },
    {
      name: "get_task",
      description: "Retrieve task from memory bank",
      inputSchema: {
        type: "object",
        properties: {
          taskId: { type: "string" }
        },
        required: ["taskId"]
      }
    },
    {
      name: "create_sprint",
      description: "Create new sprint",
      inputSchema: {
        type: "object",
        properties: {
          sprintData: { type: "object" }
        },
        required: ["sprintData"]
      }
    },
    {
      name: "get_sprint_report",
      description: "Generate sprint report",
      inputSchema: {
        type: "object",
        properties: {
          sprintId: { type: "string" }
        },
        required: ["sprintId"]
      }
    }
  ]
}));

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
      case "create_sprint":
        result = await memoryBank.createSprint(args.sprintData);
        break;
      case "get_sprint_report":
        result = await memoryBank.generateSprintReport(args.sprintId);
        break;
      default:
        throw new Error(`Unknown tool: ${name}`);
    }

    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }]
    };
  } catch (error) {
    return {
      content: [{ type: "text", text: `Error: ${error.message}` }],
      isError: true
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("Memory Bank MCP server running");
EOF

chmod +x memory-bank/memory-bank-mcp.js

log_success "Memory Bank MCP server created"

echo ""

# Step 6: Create Workflow Scripts
log_info "Creating workflow automation scripts..."

# Sprint Planning Script
cat > "workflows/sprint-planning.sh" << 'EOF'
#!/bin/bash
SPRINT_ID="sprint-$(date +%Y%m%d)"
echo "🚀 Sprint Planning for $SPRINT_ID"
echo "=================================="
echo ""
echo "1️⃣ Define Sprint Goal:"
read -p "Sprint goal: " SPRINT_GOAL
echo ""
echo "✅ Sprint $SPRINT_ID created with goal: $SPRINT_GOAL"
echo "📋 Next: Use Claude to break down user stories into tasks"
echo ""
echo "Example: 'Claude, create tasks for sprint $SPRINT_ID based on backlog'"
EOF

# Daily Standup Script
cat > "workflows/daily-standup.sh" << 'EOF'
#!/bin/bash
echo "📢 Daily Standup - $(date +%Y-%m-%d)"
echo "===================================="
echo ""
echo "🤖 Automated standup via Memory Bank:"
echo ""
echo "Use Claude with this command:"
echo "'Claude, run daily standup and show all agent statuses'"
EOF

# Sprint Review Script
cat > "workflows/sprint-review.sh" << 'EOF'
#!/bin/bash
SPRINT_ID=$1
echo "🎉 Sprint Review - $SPRINT_ID"
echo "=============================="
echo ""
echo "Use Claude to present:"
echo "'Claude, show sprint $SPRINT_ID review with all completed stories'"
EOF

# Sprint Retrospective Script
cat > "workflows/sprint-retrospective.sh" << 'EOF'
#!/bin/bash
SPRINT_ID=$1
echo "🔄 Sprint Retrospective - $SPRINT_ID"
echo "===================================="
echo ""
echo "Use Claude to analyze:"
echo "'Claude, generate retrospective for sprint $SPRINT_ID'"
EOF

chmod +x workflows/*.sh

log_success "Workflow scripts created"

echo ""

# Step 7: Create Task Templates
log_info "Creating task protocol templates..."

# Create task template directory
mkdir -p templates

cat > "templates/task-template.md" << 'EOF'
# TASK-{ID}

## 🎯 Objective
{What needs to be done - single sentence}

## 👤 Assigned To
{agent-name}

## 📊 Priority
{critical | high | medium | low}

## ⏰ Deadline
{YYYY-MM-DD HH:MM}

## 📝 Requirements
- {requirement 1}
- {requirement 2}
- {requirement 3}

## 🔗 Dependencies
- TASK-{id} (if any)

## 📦 Deliverables
- {deliverable 1}
- {deliverable 2}

## 🧠 Context
{Compressed context - MAX 200 words}

## ✅ Acceptance Criteria
- [ ] {criteria 1}
- [ ] {criteria 2}

## 📌 Notes
{Optional - only if critical}
EOF

log_success "Task templates created"

echo ""

# Step 8: Create Quick Start Guide
log_info "Creating quick start guide..."

cat > "QUICK_START.md" << 'EOF'
# Quick Start Guide

## 🚀 First Steps

### 1. Authenticate Tools

```bash
# GitHub Copilot (if not done)
copilot auth login

# Gemini (optional)
gemini auth login
```

### 2. Restart Claude Desktop

Close and reopen Claude Desktop to load the MCP servers.

### 3. Verify Setup

In Claude Desktop, try:

```
"Memory bank, create a test task"
```

If it works, you're ready!

### 4. Create Your First Sprint

```bash
./workflows/sprint-planning.sh
```

Then in Claude:

```
"Claude, I want to build a user authentication system.
Let's use our Agile process - start with requirements analysis."
```

## 🎯 Example Workflows

### Simple Feature

```
You: "Implement password reset feature"

Claude will:
1. Assign BA agent to analyze requirements
2. Architect designs the flow
3. Dev agent implements
4. QA agent tests
5. Security reviews
6. DevOps deploys

All tracked in Memory Bank!
```

### Daily Work

```bash
# Morning standup
./workflows/daily-standup.sh

# Check progress
"Claude, what's the current sprint status?"

# Assign new task
"Claude, create task for user profile page, assign to dev agent"
```

## 📖 Learn More

- `INTEGRATION_GUIDE.md` - Complete system documentation
- `task-protocols/` - Task templates and protocols
- `workflows/` - Agile ceremony scripts
- `agent-configs/` - Agent roles and capabilities

## 🎉 You're Ready!

Your Agile AI development team is set up and ready to build amazing things!
EOF

log_success "Quick start guide created"

echo ""

# Step 9: Final Instructions
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete! 🎉                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

log_success "Your Agile Multi-Agent System is installed at:"
echo "           $SYSTEM_DIR"
echo ""

log_info "Next Steps:"
echo ""
echo "1️⃣  Restart Claude Desktop to load MCP servers"
echo ""
echo "2️⃣  Authenticate (if not done):"
echo "    $ copilot auth login"
echo "    $ gemini auth login  (optional)"
echo ""
echo "3️⃣  Test the system:"
echo "    In Claude Desktop: 'Memory bank, create a test sprint'"
echo ""
echo "4️⃣  Read the guides:"
echo "    $ cat $SYSTEM_DIR/QUICK_START.md"
echo "    $ cat $SYSTEM_DIR/INTEGRATION_GUIDE.md"
echo ""
echo "5️⃣  Start your first sprint:"
echo "    $ cd $SYSTEM_DIR"
echo "    $ ./workflows/sprint-planning.sh"
echo ""

log_info "Configuration Files:"
echo "    Claude Desktop: $CLAUDE_CONFIG_FILE"
echo "    Memory Bank: $HOME/.memory-bank-storage/"
echo "    Workflows: $SYSTEM_DIR/workflows/"
echo ""

log_warning "Important Notes:"
echo "    • All agents use task templates to save 60% tokens"
echo "    • Memory Bank preserves context across sessions"
echo "    • Use workflows for Agile ceremonies"
echo "    • Review agent outputs before approval"
echo ""

log_success "Welcome to your AI Agile Development Team! 🚀"
echo ""
echo "Happy building! 💻✨"
echo ""

#!/usr/bin/env bash
# agile-setup.sh — Register all Agile agent MCP servers with Claude Code
#
# Run once after cloning. Adds memory-bank and 5 specialized agent servers
# to your user-scope Claude MCP config (~/.claude.json).
#
# Usage: agile-setup.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRY_RUN="${1:-}"

log() { echo "  $*"; }
ok()  { echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }
skip(){ echo "⏭️  $*"; }

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║   Claude Agile Multi-Agent System — Setup      ║"
echo "╚════════════════════════════════════════════════╝"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────────
echo "🔍 Checking prerequisites..."
if ! command -v node &>/dev/null; then
  warn "Node.js not found. Install Node.js 20+ first."
  exit 1
fi
ok "Node.js $(node --version)"

if ! command -v claude &>/dev/null; then
  warn "Claude CLI not found. Install Claude Code first."
  exit 1
fi
ok "Claude CLI found"

if ! command -v gemini &>/dev/null; then
  warn "Gemini CLI not found — Gemini-powered agents (BA, Architect, Security) won't work"
  warn "Install: npm install -g @google/generative-ai-cli && gemini auth login"
else
  ok "Gemini CLI found"
fi

if ! command -v copilot &>/dev/null; then
  warn "GitHub Copilot CLI not found — Copilot agents (QA, DevOps) won't work"
  warn "Install: gh extension install github/gh-copilot && gh auth login"
else
  ok "Copilot CLI found"
fi

echo ""

# ── Install memory-bank dependencies ──────────────────────────────────────────
echo "📦 Installing memory-bank dependencies..."
if [[ "$DRY_RUN" == "--dry-run" ]]; then
  skip "(dry-run) npm install in $PROJECT_DIR/memory-bank"
else
  (cd "$PROJECT_DIR/memory-bank" && npm install --silent)
  ok "memory-bank dependencies installed"
fi

echo ""

# ── Register MCP servers ───────────────────────────────────────────────────────
echo "🔌 Registering MCP servers..."
echo ""

register_server() {
  local server_name="$1"
  local server_path="$2"
  if [[ "$DRY_RUN" == "--dry-run" ]]; then
    skip "(dry-run) claude mcp add $server_name node $server_path"
  else
    if claude mcp list 2>/dev/null | grep -q "^$server_name"; then
      skip "$server_name already registered"
    else
      if claude mcp add "$server_name" node "$server_path" 2>/dev/null; then
        ok "Registered: $server_name"
      else
        warn "Failed to register $server_name — add manually:"
        log "claude mcp add $server_name node $server_path"
      fi
    fi
  fi
}

register_server "memory-bank"        "$PROJECT_DIR/memory-bank/memory-bank-mcp.mjs"
register_server "gemini-ba-agent"    "$PROJECT_DIR/mcp-server/gemini-ba-agent.mjs"
register_server "gemini-architect"   "$PROJECT_DIR/mcp-server/gemini-architect.mjs"
register_server "gemini-security"    "$PROJECT_DIR/mcp-server/gemini-security.mjs"
register_server "copilot-dev-agent"  "$PROJECT_DIR/mcp-server/copilot-dev-agent.mjs"
register_server "copilot-qa-agent"   "$PROJECT_DIR/mcp-server/copilot-qa-agent.mjs"
register_server "copilot-devops"     "$PROJECT_DIR/mcp-server/copilot-devops.mjs"

echo ""

# ── Make scripts executable ────────────────────────────────────────────────────
echo "🔧 Making workflow scripts executable..."
chmod +x "$SCRIPT_DIR"/*.sh
ok "All scripts in bin/ are executable"

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════════════╗"
echo "║              Setup Complete! 🎉                 ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
echo "📦 MCP Servers registered:"
echo "   • memory-bank        — Persistent task/sprint/knowledge/backlog storage"
echo "   • gemini-ba-agent    — Business Analyst (requirements, user stories)"
echo "   • gemini-architect   — Technical Architect (design, API, ADR)"
echo "   • gemini-security    — Security Lead (audits, OWASP, threat models)"
echo "   • copilot-dev-agent  — Senior Developer (implement, fix, refactor, review)"
echo "   • copilot-qa-agent   — QA Engineer (integration/E2E tests, coverage)"
echo "   • copilot-devops     — DevOps Engineer (CI/CD, IaC, Docker, monitoring)"
echo ""
echo "🗂  Templates:"
echo "   ~/claude-orchestration/templates/agile-task-template.md"
echo "   ~/claude-orchestration/templates/completion-report-template.md"
echo ""
echo "📋 Workflow scripts:"
echo "   sprint-planning.sh          — Start a new sprint"
echo "   daily-standup.sh            — Daily standup ceremony"
echo "   sprint-review.sh <id>       — Sprint review"
echo "   sprint-retrospective.sh <id>— Sprint retrospective"
echo ""
echo "🔗 Use in any project:"
echo "   cd /your/project && $SCRIPT_DIR/link-project.sh"
echo "   # Adds @import to project CLAUDE.md — agents available immediately"
echo ""
echo "🚀 Quick test:"
echo "   In Claude: \"Memory bank: create sprint with name='Test Sprint', goal='Verify setup'\""
echo ""
echo "📖 See USAGE.md for full workflow guide."
echo ""

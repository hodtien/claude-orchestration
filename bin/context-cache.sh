#!/usr/bin/env bash
# context-cache.sh — Generate and cache reusable project context for subagents
#
# Avoids each task spec repeating project overview, file structure, etc.
# Task specs reference cached context via: context_cache: [project-overview, file-tree]
#
# Usage:
#   context-cache.sh generate                # generate all context caches
#   context-cache.sh generate project-overview  # generate specific cache
#   context-cache.sh list                    # list available caches
#   context-cache.sh show <name>             # show cache content
#   context-cache.sh clean                   # remove all caches
#
# Cache dir: <project>/.orchestration/context-cache/
# Task specs use: context_cache: [project-overview, file-tree]

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CACHE_DIR="$PROJECT_ROOT/.orchestration/context-cache"
mkdir -p "$CACHE_DIR"

ACTION="${1:-list}"
TARGET="${2:-all}"

# ── generators ────────────────────────────────────────────────────────────────

generate_project_overview() {
  local out="$CACHE_DIR/project-overview.md"
  {
    echo "# Project Overview (auto-generated)"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Root: $PROJECT_ROOT"
    echo ""

    # Try CLAUDE.md, README.md, or AGENT_RULES.md for project description
    for f in CLAUDE.md README.md AGENT_RULES.md; do
      if [ -f "$PROJECT_ROOT/$f" ]; then
        echo "## From $f"
        # Extract first meaningful section (up to 100 lines)
        head -100 "$PROJECT_ROOT/$f"
        echo ""
        break
      fi
    done

    # Go module info
    if [ -f "$PROJECT_ROOT/go.mod" ]; then
      echo "## Go Module"
      head -3 "$PROJECT_ROOT/go.mod"
      echo ""
    fi

    # Package.json info
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      echo "## Node Package"
      python3 -c "
import json
d = json.load(open('$PROJECT_ROOT/package.json'))
print(f\"Name: {d.get('name', '?')}\")
print(f\"Version: {d.get('version', '?')}\")
print(f\"Description: {d.get('description', '?')}\")
" 2>/dev/null || true
      echo ""
    fi

    # Git info
    echo "## Git"
    echo "Branch: $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo '?')"
    echo "Last commit: $(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || echo '?')"
    echo ""

  } > "$out"
  echo "[cache] project-overview → $(wc -c < "$out" | tr -d ' ') bytes"
}

generate_file_tree() {
  local out="$CACHE_DIR/file-tree.md"
  {
    echo "# File Tree (auto-generated)"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Root: $PROJECT_ROOT"
    echo ""
    echo '```'
    # Respect .gitignore, exclude vendor/node_modules, max depth 3
    if command -v tree >/dev/null 2>&1; then
      tree -L 3 -I 'vendor|node_modules|.git|.orchestration|__pycache__|.DS_Store' "$PROJECT_ROOT" 2>/dev/null | head -200
    else
      find "$PROJECT_ROOT" -maxdepth 3 \
        -not -path '*/vendor/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/.orchestration/*' \
        -not -name '.DS_Store' \
        -print 2>/dev/null | sort | head -200 | sed "s|$PROJECT_ROOT/||"
    fi
    echo '```'
  } > "$out"
  echo "[cache] file-tree → $(wc -c < "$out" | tr -d ' ') bytes"
}

generate_architecture() {
  local out="$CACHE_DIR/architecture.md"
  {
    echo "# Architecture Context (auto-generated)"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""

    # Extract architecture section from CLAUDE.md or AGENT_RULES.md
    for f in CLAUDE.md AGENT_RULES.md; do
      if [ -f "$PROJECT_ROOT/$f" ]; then
        # Extract sections with "Architecture", "Key Packages", "Config"
        awk '/^##.*[Aa]rchitect|^##.*[Kk]ey [Pp]ackage|^##.*[Cc]onfig/{found=1} found{print} /^##/{if(found && !/[Aa]rchitect|[Kk]ey|[Cc]onfig/) found=0}' "$PROJECT_ROOT/$f"
        break
      fi
    done

    # Config file structure (if TOML)
    local config_files
    config_files=$(find "$PROJECT_ROOT/config" -name '*.toml' -maxdepth 1 2>/dev/null | head -5)
    if [ -n "$config_files" ]; then
      echo ""
      echo "## Config Files"
      for cf in $config_files; do
        echo "- $(basename "$cf"): $(grep -c '^\[' "$cf" 2>/dev/null || echo '?') sections"
      done
    fi

  } > "$out"
  echo "[cache] architecture → $(wc -c < "$out" | tr -d ' ') bytes"
}

generate_tech_stack() {
  local out="$CACHE_DIR/tech-stack.md"
  {
    echo "# Tech Stack (auto-generated)"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""

    # Go version
    if [ -f "$PROJECT_ROOT/go.mod" ]; then
      echo "- **Language**: Go $(grep '^go ' "$PROJECT_ROOT/go.mod" | awk '{print $2}' 2>/dev/null || echo '?')"
    fi

    # Node version
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      echo "- **Node**: $(node --version 2>/dev/null || echo '?')"
    fi

    # Dockerfile base
    if [ -f "$PROJECT_ROOT/Dockerfile" ]; then
      echo "- **Docker base**: $(grep '^FROM' "$PROJECT_ROOT/Dockerfile" | head -1 | awk '{print $2}')"
    fi

    # Database from config
    if grep -rq 'postgis\|postgres' "$PROJECT_ROOT/config/" 2>/dev/null; then
      echo "- **Database**: PostgreSQL + PostGIS"
    fi
    if grep -rq 'redis' "$PROJECT_ROOT/config/" 2>/dev/null; then
      echo "- **Cache**: Redis"
    fi
    if grep -rq 'kafka' "$PROJECT_ROOT/config/" 2>/dev/null; then
      echo "- **Events**: Kafka"
    fi

  } > "$out"
  echo "[cache] tech-stack → $(wc -c < "$out" | tr -d ' ') bytes"
}

# ── commands ──────────────────────────────────────────────────────────────────

do_generate() {
  local target="$1"
  case "$target" in
    all)
      generate_project_overview
      generate_file_tree
      generate_architecture
      generate_tech_stack
      echo "[cache] all caches generated in $CACHE_DIR"
      ;;
    project-overview) generate_project_overview ;;
    file-tree)        generate_file_tree ;;
    architecture)     generate_architecture ;;
    tech-stack)       generate_tech_stack ;;
    *)
      echo "[cache] unknown cache: $target" >&2
      echo "[cache] available: project-overview, file-tree, architecture, tech-stack" >&2
      exit 1 ;;
  esac
}

do_list() {
  echo "=== Context Cache ==="
  for f in "$CACHE_DIR"/*.md; do
    [ -f "$f" ] || continue
    local name size age
    name=$(basename "$f" .md)
    size=$(wc -c < "$f" | tr -d ' ')
    age=$(( ( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) ) / 60 ))
    echo "  $name — ${size} bytes (${age}m ago)"
  done
  if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
    echo "  (empty — run 'context-cache.sh generate' first)"
  fi
}

do_show() {
  local name="$1"
  local path="$CACHE_DIR/${name}.md"
  if [ ! -f "$path" ]; then
    echo "[cache] not found: $name" >&2
    do_list
    exit 1
  fi
  cat "$path"
}

do_clean() {
  rm -f "$CACHE_DIR"/*.md
  echo "[cache] cleaned"
}

case "$ACTION" in
  generate) do_generate "$TARGET" ;;
  list)     do_list ;;
  show)     do_show "$TARGET" ;;
  clean)    do_clean ;;
  --help|-h)
    echo "Usage: context-cache.sh <generate|list|show|clean> [target]"
    echo "Targets: all, project-overview, file-tree, architecture, tech-stack"
    ;;
  *) echo "[cache] unknown action: $ACTION" >&2; exit 1 ;;
esac

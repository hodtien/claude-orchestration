#!/usr/bin/env bash
# Wrapper — delegates to bin/sprint-planning.sh (which is in PATH)
exec "$(dirname "$0")/../bin/sprint-planning.sh" "$@"

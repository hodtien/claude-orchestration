#!/usr/bin/env bash
# Wrapper — delegates to bin/sprint-retrospective.sh (which is in PATH)
exec "$(dirname "$0")/../bin/sprint-retrospective.sh" "$@"

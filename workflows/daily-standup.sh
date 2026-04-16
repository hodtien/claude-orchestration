#!/usr/bin/env bash
# Wrapper — delegates to bin/daily-standup.sh (which is in PATH)
exec "$(dirname "$0")/../bin/daily-standup.sh" "$@"

#!/usr/bin/env bash
# Wrapper — delegates to bin/sprint-review.sh (which is in PATH)
exec "$(dirname "$0")/../bin/sprint-review.sh" "$@"

#!/usr/bin/env bash
# notify-lib.sh — sourced by task-dispatch.sh and others
# Thin wrapper that fires orch-notify-send.sh in the background.
# Never blocks. Never fails. Safe to source even if notify script is absent.
_NOTIFY_SH="${_NOTIFY_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orch-notify-send.sh}"

notify_event() {
  local event="$1" payload="$2"
  [ -x "$_NOTIFY_SH" ] || return 0
  "$_NOTIFY_SH" "$event" "$payload" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

#!/usr/bin/env bash
# circuit-breaker.sh — per-agent circuit breaker state manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_FILE="${PROJECT_ROOT}/.orchestration/circuit-breaker.json"

WINDOW_SECONDS=300
FAILURE_THRESHOLD=3
OPEN_TIMEOUT_SECONDS=300

usage() {
  echo "Usage: circuit-breaker.sh <check|record-success|record-failure|status|reset> [agent]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
COMMAND="$1"
AGENT="${2:-}"

case "$COMMAND" in
  check|record-success|record-failure|reset)
    [ -n "$AGENT" ] || usage
    ;;
  status) ;;
  *)
    usage
    ;;
esac

mkdir -p "$(dirname "$STATE_FILE")"
[ -f "$STATE_FILE" ] || printf '{}\n' > "$STATE_FILE"

python3 - "$STATE_FILE" "$COMMAND" "$AGENT" "$WINDOW_SECONDS" "$FAILURE_THRESHOLD" "$OPEN_TIMEOUT_SECONDS" <<'PYEOF'
import fcntl
import json
import os
import sys
import time
from typing import Any, Dict, List

_, state_file, command, agent, window_raw, threshold_raw, open_timeout_raw = sys.argv
window_seconds = int(window_raw)
failure_threshold = int(threshold_raw)
open_timeout_seconds = int(open_timeout_raw)
now = int(time.time())


def notify_circuit_open(agent_name: str, entry: dict, prev_state: str) -> None:
    """Fire circuit_open notification u2014 never raises."""
    try:
        import subprocess as _sp
        notify_sh = os.path.realpath(
            os.path.join(os.path.dirname(state_file), '..', 'bin', 'orch-notify-send.sh'))
        if not os.path.isfile(notify_sh):
            return
        payload = json.dumps({
            'agent': agent_name,
            'failures': len(entry.get('failure_history', [])),
            'window_seconds': window_seconds,
            'threshold': failure_threshold,
            'open_timeout_seconds': open_timeout_seconds,
            'last_failure_ts': entry.get('last_failure'),
            'previous_state': prev_state,
        })
        _sp.Popen([notify_sh, 'circuit_open', payload],
                  stdout=_sp.DEVNULL, stderr=_sp.DEVNULL, start_new_session=True)
    except Exception:
        pass

VALID_STATES = {"CLOSED", "OPEN", "HALF-OPEN"}

def load_state() -> Dict[str, Any]:
    try:
        with open(state_file, "r", encoding="utf-8") as fh:
            data = json.load(fh)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_state(state: Dict[str, Any]) -> None:
    tmp_file = f"{state_file}.tmp.{os.getpid()}"
    with open(tmp_file, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp_file, state_file)

def as_int_or_none(value: Any) -> Any:
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

def normalize_history(value: Any) -> List[int]:
    out: List[int] = []
    if isinstance(value, list):
        for item in value:
            iv = as_int_or_none(item)
            if iv is not None:
                out.append(iv)
    return out

def normalize_entry(entry: Any) -> Dict[str, Any]:
    base = entry if isinstance(entry, dict) else {}
    state = str(base.get("state", "CLOSED")).upper()
    if state not in VALID_STATES:
        state = "CLOSED"
    history = normalize_history(base.get("failure_history"))
    failures_value = base.get("failures", len(history))
    try:
        failures = int(failures_value)
    except (TypeError, ValueError):
        failures = len(history)
    return {
        "state": state,
        "failures": max(0, failures),
        "last_failure": as_int_or_none(base.get("last_failure")),
        "last_probe": as_int_or_none(base.get("last_probe")),
        "failure_history": history,
    }

def with_history(entry: Dict[str, Any], history: List[int]) -> None:
    entry["failure_history"] = history
    entry["failures"] = len(history)

lock_file = f"{state_file}.lock"
with open(lock_file, "a+", encoding="utf-8") as lock_handle:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
    state = load_state()

    if command == "status":
        if not state:
            print("no agents tracked")
            sys.exit(0)
        print("AGENT\tSTATE\tFAILURES\tLAST_FAILURE\tLAST_PROBE")
        for agent_name in sorted(state):
            entry = normalize_entry(state.get(agent_name))
            last_failure = "" if entry["last_failure"] is None else str(entry["last_failure"])
            last_probe = "" if entry["last_probe"] is None else str(entry["last_probe"])
            print(f"{agent_name}\t{entry['state']}\t{entry['failures']}\t{last_failure}\t{last_probe}")
        sys.exit(0)

    entry = normalize_entry(state.get(agent))

    if command == "check":
        if entry["state"] == "OPEN":
            opened_at = entry["last_probe"] if entry["last_probe"] is not None else entry["last_failure"]
            if opened_at is None:
                opened_at = now
            if now - int(opened_at) >= open_timeout_seconds:
                entry["state"] = "HALF-OPEN"
                entry["last_probe"] = now
                state[agent] = entry
                save_state(state)
                sys.exit(0)
            sys.exit(1)
        if entry["state"] == "HALF-OPEN":
            sys.exit(0)
        sys.exit(0)

    if command == "record-success":
        entry["state"] = "CLOSED"
        entry["last_probe"] = now
        entry["last_failure"] = entry.get("last_failure")
        with_history(entry, [])
        state[agent] = entry
        save_state(state)
        sys.exit(0)

    if command == "record-failure":
        if entry["state"] == "HALF-OPEN":
            entry["state"] = "OPEN"
            entry["last_failure"] = now
            entry["last_probe"] = now
            with_history(entry, [now])
            state[agent] = entry
            save_state(state)
            notify_circuit_open(agent, entry, "HALF-OPEN")
            sys.exit(0)

        history = [ts for ts in entry["failure_history"] if now - ts <= window_seconds]
        history.append(now)
        with_history(entry, history)
        entry["last_failure"] = now
        if len(history) >= failure_threshold:
            prev_state = entry["state"]
            entry["state"] = "OPEN"
            entry["last_probe"] = now
            state[agent] = entry
            save_state(state)
            notify_circuit_open(agent, entry, prev_state)
        else:
            entry["state"] = "CLOSED"
            state[agent] = entry
            save_state(state)
        sys.exit(0)

    if command == "reset":
        state[agent] = {
            "state": "CLOSED",
            "failures": 0,
            "last_failure": None,
            "last_probe": None,
            "failure_history": [],
        }
        save_state(state)
        sys.exit(0)

sys.exit(2)
PYEOF

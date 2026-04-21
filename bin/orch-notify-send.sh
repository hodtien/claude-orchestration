#!/usr/bin/env bash
# orch-notify-send.sh u2014 Route orchestration events to Slack / HTTP webhooks / file log
# Usage:
#   orch-notify-send.sh <event> <json_payload>   fire a notification
#   orch-notify-send.sh test [channel_name]       send test notification
#   orch-notify-send.sh channels                  list configured channels
#   orch-notify-send.sh validate                  parse config and report issues
# Exits 0 on success or any internal error (failure isolation for fire-and-forget use).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null \
               || (cd "$SCRIPT_DIR/.." && pwd))"
CONF_FILE="${ORCH_NOTIFY_CONF:-${PROJECT_ROOT}/.orchestration/notify.conf}"

CMD="${1:-}"
case "$CMD" in
  -h|--help|"")
    sed -n '2,10p' "$0" >&2
    exit 2
    ;;
esac

# Main: always exit 0 to preserve failure isolation for fire-and-forget callers.
# test / validate / channels may exit non-zero for diagnostic feedback.
python3 - "$CONF_FILE" "$PROJECT_ROOT" "$@" <<'PY' || true
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

conf_file = Path(sys.argv[1])
project_root = Path(sys.argv[2])
cmd_args = sys.argv[3:]  # original $@
cmd = cmd_args[0] if cmd_args else ""
remaining = cmd_args[1:]

# ---------------------------------------------------------------------------
# Config loader
# ---------------------------------------------------------------------------

DEFAULT_EVENTS = {
    "batch_complete": True,
    "batch_partial_failure": True,
    "task_failed": False,
    "slo_breach": True,
    "circuit_open": True,
    "scheduled_dispatch": False,
}

ALL_EVENTS = set(DEFAULT_EVENTS.keys())
SEVERITY_ORDER = {"info": 0, "warn": 1, "error": 2}


def _parse_value(raw):
    v = raw.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    lo = v.lower()
    if lo in ("true", "1", "yes", "on"):
        return True
    if lo in ("false", "0", "no", "off"):
        return False
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        if not inner:
            return []
        return [p.strip().strip('"').strip("'") for p in inner.split(",") if p.strip()]
    return v


def _parse_simple_yaml(text):
    """Very minimal YAML parser supporting flat key:value and one-level lists."""
    result = {}
    current_key = None
    in_list = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Detect list items
        if stripped.startswith("- ") and current_key and isinstance(result.get(current_key), list):
            # Block-style list item under current_key
            result[current_key].append(_parse_value(stripped[2:]))
            continue
        m = re.match(r"^([A-Za-z_][\w.-]*)\s*:\s*(.*)", stripped)
        if m:
            k, v = m.group(1), m.group(2).strip()
            if v == "":
                # Next items may be list items or sub-map; skip sub-maps for simplicity
                result[k] = result.get(k, [])
                current_key = k
            else:
                result[k] = _parse_value(v)
                current_key = k
    return result


def _load_yaml_channel(block_lines):
    """Parse a channel block (list of indented lines)."""
    channel = {}
    headers = {}
    in_headers = False
    for line in block_lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("- "):
            # Nested list item under headers
            if in_headers:
                k, _, v = s[2:].partition(":")
                headers[k.strip()] = v.strip().strip('"').strip("'")
            continue
        m = re.match(r"^([A-Za-z_][\w.-]*)\s*:\s*(.*)", s)
        if m:
            k, v = m.group(1), m.group(2).strip()
            in_headers = k == "headers"
            if in_headers and v == "":
                channel["headers"] = headers
            else:
                channel[k] = _parse_value(v) if v else ([] if k in ("events", "headers") else "")
    if headers:
        channel["headers"] = headers
    return channel


def load_config(path):
    """Load and validate notify.conf."""
    default_file_channel = {
        "type": "file",
        "name": "default-file",
        "path": str(project_root / ".orchestration" / "notifications.log"),
        "events": ["all"],
        "enabled": True,
    }

    if not path.is_file():
        return {
            "enabled": True,
            "min_severity": "info",
            "events": dict(DEFAULT_EVENTS),
            "channels": [default_file_channel],
        }

    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return {
            "enabled": True,
            "min_severity": "info",
            "events": dict(DEFAULT_EVENTS),
            "channels": [default_file_channel],
        }

    # Split top-level keys vs channel blocks
    top = {}
    event_section = False
    channel_blocks = []
    current_block = None
    events_dict = dict(DEFAULT_EVENTS)

    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            event_section = False
            continue
        if s == "channels:":
            event_section = False
            current_block = None
            continue
        if s == "events:":
            event_section = True
            continue
        if re.match(r"^\s{0,2}- ", line) and not line.startswith("  "):
            # New channel block
            current_block = [line]
            channel_blocks.append(current_block)
            event_section = False
            continue
        if current_block is not None and (line.startswith(" ") or line.startswith("\t") or s.startswith("- ")):
            current_block.append(line)
            continue
        if event_section and s:
            m = re.match(r"^([A-Za-z_][\w.-]*)\s*:\s*(.*)", s)
            if m:
                k, v = m.group(1), _parse_value(m.group(2).strip())
                if k in DEFAULT_EVENTS:
                    events_dict[k] = bool(v)
            continue
        m = re.match(r"^([A-Za-z_][\w.-]*)\s*:\s*(.*)", s)
        if m:
            k, v = m.group(1), m.group(2).strip()
            top[k] = _parse_value(v) if v else ""

    channels = []
    for block in channel_blocks:
        ch = _load_yaml_channel(block)
        if ch.get("type"):
            channels.append(ch)

    # Ensure file channel always present if none defined
    has_file = any(c.get("type") == "file" for c in channels)
    if not has_file:
        channels.append(default_file_channel)

    return {
        "enabled": bool(top.get("enabled", True)),
        "min_severity": str(top.get("min_severity", "info")),
        "events": events_dict,
        "channels": channels,
    }


# ---------------------------------------------------------------------------
# Payload enrichment
# ---------------------------------------------------------------------------

EVENT_SEVERITY = {
    "task_failed": "error",
    "circuit_open": "error",
    "batch_partial_failure": "warn",
    "slo_breach": "warn",
    "batch_complete": "info",   # overridden by result below
    "scheduled_dispatch": "info",
}


def compute_severity(event, details):
    if event == "batch_complete":
        r = str(details.get("result", "")).upper()
        if r == "FAILED":
            return "error"
        if r == "PARTIAL":
            return "warn"
        return "info"
    return EVENT_SEVERITY.get(event, "info")


SUMMARY_TEMPLATES = {
    "batch_complete": "Batch {batch_id} {result} \u2014 {success_count}/{total_tasks} tasks in {duration_s}s",
    "batch_partial_failure": "Batch {batch_id} PARTIAL \u2014 {success_count}/{total_tasks} succeeded, {failed_count} failed",
    "task_failed": "Task {task_id} FAILED on {agent} after {retries} retries ({duration_s}s)",
    "slo_breach": "SLO breach: {task_id} took {actual_duration_s}s (SLO={slo_duration_s}s, ratio={breach_ratio}x)",
    "circuit_open": "Circuit OPEN for agent {agent} \u2014 {failures} failures in {window_seconds}s window",
    "scheduled_dispatch": "Scheduled dispatch fired: {schedule_id} \u2192 {dispatched_task_id}",
}


def render_summary(event, details):
    tmpl = SUMMARY_TEMPLATES.get(event, "Event: {event}")
    merged = {"event": event, **details}
    try:
        return tmpl.format_map({k: merged.get(k, "") for k in re.findall(r"\{(\w+)\}", tmpl)})
    except Exception:
        return f"{event} notification"


def enrich(event, details_input):
    # If caller already passed a full envelope, use it directly
    if isinstance(details_input, dict) and details_input.get("schema_version"):
        return details_input
    details = details_input if isinstance(details_input, dict) else {}
    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sev = compute_severity(event, details)
    # Determine result for batch_complete
    result = details.get("result") or None
    if event == "batch_complete" and result is None:
        sc = int(details.get("success_count", 0))
        fc = int(details.get("failed_count", 0))
        total = int(details.get("total_tasks", sc + fc))
        if fc == 0:
            result = "SUCCESS"
        elif sc == 0:
            result = "FAILED"
        else:
            result = "PARTIAL"
        details["result"] = result
    return {
        "schema_version": "1",
        "event": event,
        "ts": now_utc,
        "project": str(project_root),
        "project_name": project_root.name,
        "host": socket.gethostname(),
        "trace_id": os.environ.get("ORCH_TRACE_ID"),
        "batch_id": details.get("batch_id"),
        "task_id": details.get("task_id"),
        "severity": sev,
        "summary": render_summary(event, details),
        "result": result,
        "details": details,
    }


# ---------------------------------------------------------------------------
# Channel filters
# ---------------------------------------------------------------------------

def event_globally_enabled(cfg, event):
    if not cfg.get("enabled", True):
        return False
    return bool(cfg.get("events", {}).get(event, DEFAULT_EVENTS.get(event, False)))


def channel_accepts(channel, event, severity):
    if not channel.get("enabled", True):
        return False
    evts = channel.get("events", ["all"])
    if not evts:
        evts = ["all"]
    if "all" not in evts and event not in evts:
        return False
    ch_min = channel.get("min_severity", "info")
    global_min = "info"
    if SEVERITY_ORDER.get(severity, 0) < SEVERITY_ORDER.get(ch_min, 0):
        return False
    return True


# ---------------------------------------------------------------------------
# Senders
# ---------------------------------------------------------------------------

EVENT_EMOJI = {
    "batch_complete/SUCCESS": "\u2705",
    "batch_complete/PARTIAL": "\u26a0\ufe0f",
    "batch_complete/FAILED": "\u274c",
    "task_failed": "\u274c",
    "slo_breach": "\u23f1\ufe0f",
    "circuit_open": "\u26a1",
    "scheduled_dispatch": "\u23f0",
    "batch_partial_failure": "\u26a0\ufe0f",
}


def _emoji(event, result):
    key = f"{event}/{result}" if result else event
    return EVENT_EMOJI.get(key, EVENT_EMOJI.get(event, "\u2139\ufe0f"))


def _build_slack_payload(channel, envelope):
    event = envelope.get("event", "")
    details = envelope.get("details", {})
    result = envelope.get("result")
    batch_id = envelope.get("batch_id", "")
    task_id = envelope.get("task_id", "")
    summary = envelope.get("summary", "")
    trace = envelope.get("trace_id") or ""
    ts = envelope.get("ts", "")
    emoji = _emoji(event, result)

    username = channel.get("username", "orch-notify")
    icon = channel.get("icon_emoji", ":satellite_antenna:")

    if event == "batch_complete":
        title = f"{emoji} Batch {batch_id} \u2014 {result or ''}"
        fields = [
            {"type": "mrkdwn", "text": f"*Project*\n{envelope.get('project_name', '')}"},
            {"type": "mrkdwn", "text": f"*Duration*\n{details.get('duration_s', '?')}s"},
            {"type": "mrkdwn", "text": f"*Tasks*\n{details.get('total_tasks', '?')} total"},
            {"type": "mrkdwn", "text": f"*Succeeded*\n{details.get('success_count', '?')}"},
            {"type": "mrkdwn", "text": f"*Failed*\n{details.get('failed_count', '?')}"},
        ]
        blocks = [
            {"type": "header", "text": {"type": "plain_text", "text": title, "emoji": True}},
            {"type": "section", "fields": fields},
        ]
        failed_ids = details.get("failed_task_ids", [])
        if failed_ids:
            shown = failed_ids[:5]
            extra = len(failed_ids) - 5
            id_text = "\n".join(f"\u2022 {i}" for i in shown)
            if extra > 0:
                id_text += f"\n\u2026 +{extra} more"
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Failed tasks*\n{id_text}"}})
    elif event == "task_failed":
        title = f"{emoji} Task failed \u2014 {task_id}"
        err = str(details.get("error_tail", ""))[:500]
        blocks = [
            {"type": "header", "text": {"type": "plain_text", "text": title, "emoji": True}},
            {"type": "section", "fields": [
                {"type": "mrkdwn", "text": f"*Batch*\n{batch_id}"},
                {"type": "mrkdwn", "text": f"*Agent*\n{details.get('agent', '?')}"},
                {"type": "mrkdwn", "text": f"*Retries*\n{details.get('retries', '?')}"},
                {"type": "mrkdwn", "text": f"*Duration*\n{details.get('duration_s', '?')}s"},
            ]},
        ]
        if err:
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Error tail*\n```{err}```"}})
    else:
        title = f"{emoji} {event}"
        blocks = [
            {"type": "header", "text": {"type": "plain_text", "text": title, "emoji": True}},
            {"type": "section", "text": {"type": "mrkdwn", "text": summary}},
        ]

    blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": f"trace `{trace}` \u2022 `{ts}`"}]})

    payload = {"username": username, "icon_emoji": icon, "text": summary, "blocks": blocks}
    if channel.get("channel"):
        payload["channel"] = channel["channel"]
    return payload


def _curl_post(url, body_bytes, extra_headers=None, method="POST"):
    """Run curl. Returns (http_code, error_str)."""
    cmd = [
        "curl", "--silent", "--show-error",
        "--max-time", "5",
        "--connect-timeout", "3",
        "--retry", "0",
        "-X", method,
        "-H", "Content-Type: application/json",
    ]
    for k, v in (extra_headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    cmd += ["-w", "%{http_code}", "-o", "/dev/null", "--data-binary", "@-", url]
    try:
        result = subprocess.run(cmd, input=body_bytes, capture_output=True, timeout=7)
        code = result.stdout.decode().strip()
        err = result.stderr.decode().strip()
        return code, err
    except Exception as exc:
        return "", str(exc)


def send_slack(channel, envelope):
    url = channel.get("webhook_url", "")
    if not url or not url.startswith("https://"):
        raise ValueError("slack channel missing valid webhook_url")
    slack_payload = _build_slack_payload(channel, envelope)
    body = json.dumps(slack_payload).encode()
    code, err = _curl_post(url, body)
    if err:
        raise RuntimeError(f"curl error: {err}")
    if code and not code.startswith("2"):
        raise RuntimeError(f"slack returned HTTP {code}")


def send_webhook(channel, envelope):
    url = channel.get("url", "")
    if not url or not url.startswith(("http://", "https://")):
        raise ValueError("webhook channel missing valid url")
    method = str(channel.get("method", "POST")).upper()
    headers = channel.get("headers") or {}
    body = json.dumps(envelope).encode()
    code, err = _curl_post(url, body, headers, method)
    if err:
        raise RuntimeError(f"curl error: {err}")
    if code and not code.startswith("2"):
        raise RuntimeError(f"webhook returned HTTP {code}")


def send_file(channel, envelope):
    raw_path = channel.get("path", ".orchestration/notifications.log")
    p = Path(raw_path)
    if not p.is_absolute():
        p = project_root / p
    p.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(envelope, ensure_ascii=False) + "\n"
    with p.open("a", encoding="utf-8") as fh:
        fh.write(line)


SENDERS = {"slack": send_slack, "webhook": send_webhook, "file": send_file}


# ---------------------------------------------------------------------------
# Meta log (for delivery failures, never raises)
# ---------------------------------------------------------------------------

def meta_log(msg):
    try:
        p = project_root / ".orchestration" / "notifications.log"
        p.parent.mkdir(parents=True, exist_ok=True)
        entry = json.dumps({"event": "notify_send_error", "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "msg": msg}) + "\n"
        with p.open("a", encoding="utf-8") as fh:
            fh.write(entry)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

def dispatch(cfg, envelope):
    event = envelope.get("event", "")
    severity = envelope.get("severity", "info")
    for channel in cfg.get("channels", []):
        if not channel_accepts(channel, event, severity):
            continue
        ctype = channel.get("type", "")
        sender = SENDERS.get(ctype)
        if not sender:
            meta_log(f"unknown channel type '{ctype}' name={channel.get('name', '')}")
            continue
        try:
            sender(channel, envelope)
        except Exception as exc:
            meta_log(f"channel_error channel={channel.get('name', ctype)} event={event} err={exc!r}")


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def mask_url(url):
    try:
        from urllib.parse import urlparse
        p = urlparse(str(url))
        return f"{p.scheme}://{p.netloc}/****"
    except Exception:
        return "***"


def cmd_channels(cfg):
    channels = cfg.get("channels", [])
    if not channels:
        print("(no channels configured)")
        return
    print(f"{'NAME':<20} {'TYPE':<10} {'EVENTS':<30} {'SEVERITY':<10} {'ENABLED':<8} TARGET")
    for ch in channels:
        name = ch.get("name", "")
        ctype = ch.get("type", "?")
        evts = ch.get("events", ["all"])
        evts_str = ",".join(str(e) for e in evts) if evts else "all"
        sev = ch.get("min_severity", "info")
        enabled = str(ch.get("enabled", True)).lower()
        if ctype == "slack":
            target = mask_url(ch.get("webhook_url", ""))
        elif ctype == "webhook":
            target = mask_url(ch.get("url", ""))
        elif ctype == "file":
            target = str(ch.get("path", ""))
        else:
            target = "?"
        print(f"{name:<20} {ctype:<10} {evts_str:<30} {sev:<10} {enabled:<8} {target}")


def cmd_validate(cfg_path):
    errors = []
    warnings = []
    cfg = load_config(cfg_path)
    if not cfg.get("enabled", True):
        warnings.append("Notifications globally disabled (enabled: false)")
    for ch in cfg.get("channels", []):
        ctype = ch.get("type", "")
        if ctype not in ("slack", "webhook", "file"):
            errors.append(f"Unknown channel type '{ctype}'")
        if ctype == "slack":
            url = ch.get("webhook_url", "")
            if not str(url).startswith("https://"):
                errors.append(f"Slack channel '{ch.get('name', '')}' has invalid webhook_url")
        if ctype == "webhook":
            url = ch.get("url", "")
            if not str(url).startswith(("http://", "https://")):
                errors.append(f"Webhook channel '{ch.get('name', '')}' has invalid url")
    for msg in errors:
        print(f"ERROR: {msg}")
    for msg in warnings:
        print(f"WARN:  {msg}")
    if not errors and not warnings:
        print("OK: config is valid")
    return len(errors)


def cmd_test(cfg, channel_name=None):
    test_envelope = enrich("batch_complete", {
        "batch_id": "test-batch",
        "total_tasks": 4,
        "success_count": 4,
        "failed_count": 0,
        "skipped_count": 0,
        "cancelled_count": 0,
        "duration_s": 42,
        "failure_mode": "skip-failed",
        "result": "SUCCESS",
        "inbox_file": ".orchestration/inbox/test-batch.done.md",
        "failed_task_ids": [],
    })
    channels = cfg.get("channels", [])
    if channel_name:
        channels = [c for c in channels if c.get("name") == channel_name]
        if not channels:
            print(f"No channel named '{channel_name}'", file=sys.stderr)
            return 1
    ok = 0
    fail = 0
    for ch in channels:
        ctype = ch.get("type", "?")
        name = ch.get("name", ctype)
        sender = SENDERS.get(ctype)
        if not sender:
            print(f"  {name}: SKIP (unknown type {ctype})")
            continue
        try:
            sender(ch, test_envelope)
            print(f"  {name}: OK")
            ok += 1
        except Exception as exc:
            print(f"  {name}: FAIL ({exc})")
            fail += 1
    return 0 if ok > 0 else 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

cfg = load_config(conf_file)

if cmd == "channels":
    cmd_channels(cfg)
    sys.exit(0)

elif cmd == "validate":
    nerrs = cmd_validate(conf_file)
    sys.exit(1 if nerrs else 0)

elif cmd == "test":
    channel_arg = remaining[0] if remaining else None
    rc = cmd_test(cfg, channel_arg)
    sys.exit(rc)

elif cmd in ALL_EVENTS:
    # Fire notification
    if not cmd_args or len(cmd_args) < 2:
        sys.exit(0)  # No payload u2014 no-op
    raw_payload = cmd_args[1]
    try:
        details = json.loads(raw_payload)
    except Exception:
        details = {}
    if not event_globally_enabled(cfg, cmd):
        sys.exit(0)
    envelope = enrich(cmd, details)
    dispatch(cfg, envelope)
    sys.exit(0)

else:
    # Unknown event name u2014 treat as no-op for forward compat
    sys.exit(0)
PY

exit 0

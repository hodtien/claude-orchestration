#!/usr/bin/env bash
# smoke-test-context-compressor.sh — Stress-test lib/context-compressor.sh
# at multiple compression ratios (0.3 / 0.5 / 0.7).
#
# NOTE: compress_summary() is LOSSY (truncation-based summarization).
# There is NO decompress_session function. Round-trip fidelity is N/A
# for this compressor — we test that compression reduces size instead.
#
# Run standalone:  bash bin/smoke-test-context-compressor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBCOMPRESS="$PROJECT_ROOT/lib/context-compressor.sh"

# ── Guards ──────────────────────────────────────────────────────────────────
if [[ ! -f "$LIBCOMPRESS" ]]; then
  echo "ERROR: lib/context-compressor.sh not found at $LIBCOMPRESS" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$LIBCOMPRESS"

if ! declare -f compress_summary >/dev/null 2>&1; then
  echo "ERROR: compress_summary() not defined after sourcing $LIBCOMPRESS" >&2
  exit 1
fi

# ── Test payloads ────────────────────────────────────────────────────────────
PAYLOADS=(
  "$PROJECT_ROOT/bin/task-dispatch.sh"
  "$PROJECT_ROOT/.orchestration/evals/code_review/unused_variable.yaml"
  "$PROJECT_ROOT/.orchestration/evals/implement_feature/fizzbuzz.yaml"
)

RATIOS=(0.3 0.5 0.7)

# ── Output / results ─────────────────────────────────────────────────────────
RESULTS_DIR="$PROJECT_ROOT/.orchestration/evals/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
JSON_OUT="$RESULTS_DIR/compression-test-${TIMESTAMP%%T*}.json"
MARKDOWN_OUT="$RESULTS_DIR/compression-test-${TIMESTAMP%%T*}.md"

# ── Helpers ──────────────────────────────────────────────────────────────────
estimate_tokens() {
  local chars="$1"
  echo $(( (chars + 3) / 4 ))
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── Markdown table header ────────────────────────────────────────────────────
{
  printf '## Compression Test Results — %s\n\n' "$TIMESTAMP"
  printf '%-50s %-8s %-10s %-10s %-8s %-12s\n' \
    "Payload" "Ratio" "Original" "Compressed" "Actual" "Round-trip"
  printf '%s\n' "--------------------------------------------------------------------------------"
} > "$MARKDOWN_OUT"

# ── Core test loop ────────────────────────────────────────────────────────────
ALL_JSON=""

for payload in "${PAYLOADS[@]}"; do
  if [[ ! -f "$payload" ]]; then
    echo "WARNING: payload not found, skipping: $payload"
    continue
  fi

  payload_name="${payload#$PROJECT_ROOT/}"
  original_content=$(cat "$payload" 2>/dev/null || echo "")

  if [[ -z "$original_content" ]]; then
    echo "WARNING: empty or unreadable payload: $payload"
    continue
  fi

  original_chars=${#original_content}
  original_tokens=$(estimate_tokens "$original_chars")

  for ratio in "${RATIOS[@]}"; do
    compressed=""
    compress_rc=0
    compressed=$(compress_summary "$original_content" "$ratio") 2>/dev/null || compress_rc=$?

    if [[ $compress_rc -ne 0 ]]; then
      echo "ERROR: compress_summary() failed for $payload_name at ratio=$ratio (exit $compress_rc)"
      continue
    fi

    compressed_chars=${#compressed}
    compressed_tokens=$(estimate_tokens "$compressed_chars")

    if [[ "$original_chars" -gt 0 ]]; then
      ratio_actual=$(echo "scale=4; $compressed_chars / $original_chars" | bc 2>/dev/null || echo "N/A")
    else
      ratio_actual="N/A"
    fi

    roundtrip="N/A (lossy)"

    # Console output
    printf "  %-8s | ratio=%.2f | %d chars → %d chars (%.4f) | tokens %d → %d | %s\n" \
      "ratio=$ratio" \
      "$ratio" \
      "$original_chars" \
      "$compressed_chars" \
      "$ratio_actual" \
      "$original_tokens" \
      "$compressed_tokens" \
      "$roundtrip"

    # Markdown table
    printf '%-50s %-8s %-10s %-10s %-8s %-12s\n' \
      "${payload_name:0:48}" \
      "$ratio" \
      "$original_chars" \
      "$compressed_chars" \
      "$ratio_actual" \
      "$roundtrip" \
      >> "$MARKDOWN_OUT"

    # JSON row (escaped)
    row_json=$(cat <<ROWEOF
    {
      "payload": "$(json_escape "$payload_name")",
      "ratio_setting": $ratio,
      "original_chars": $original_chars,
      "compressed_chars": $compressed_chars,
      "compression_ratio_actual": "$ratio_actual",
      "original_tokens_est": $original_tokens,
      "compressed_tokens_est": $compressed_tokens,
      "round_trip": "N/A_losy",
      "compress_rc": $compress_rc
    }
ROWEOF
)
    ALL_JSON="${ALL_JSON}${row_json}"$'\n'
  done
done

# ── Write JSON results ────────────────────────────────────────────────────────
python3 - "$ALL_JSON" "$JSON_OUT" <<'PYEOF'
import json, sys

lines = sys.argv[1].strip().split('\n') if sys.argv[1].strip() else []
results = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        results.append(json.loads(line))
    except Exception as e:
        print(f"JSON parse error: {e} in: {line[:80]}", file=sys.stderr)
        pass

output = {
    "test": "context-compressor-smoke",
    "timestamp": sys.argv[2] if len(sys.argv) > 2 else "",
    "note": "compress_summary() is LOSSY (head-line truncation). No decompress_session exists. Round-trip fidelity not applicable.",
    "total_rows": len(results),
    "ratios_tested": [0.3, 0.5, 0.7],
    "token_heuristic": "chars/4",
    "results": results
}

with open(sys.argv[-1], 'w') as f:
    json.dump(output, f, indent=2)
PYEOF

# ── Summary ───────────────────────────────────────────────────────────────────
payloads_found=0
for p in "${PAYLOADS[@]}"; do [[ -f "$p" ]] && payloads_found=$((payloads_found+1)); done

total_rows=$(echo "$ALL_JSON" | grep -c '{' || echo 0)

echo ""
echo "=== Summary ==="
echo "Payloads found  : $payloads_found of ${#PAYLOADS[@]}"
echo "Ratios tested   : ${RATIOS[*]}"
echo "Total test rows : $total_rows"
echo ""
echo "Output files:"
echo "  JSON : $JSON_OUT"
echo "  MD   : $MARKDOWN_OUT"

exit 0
#!/usr/bin/env bash
# test-compressor.sh — Phase 7.3 sanity test for lib/context-compressor.sh
#
# Goal: confirm compress_summary() produces reasonable ratios on a REAL
# structured payload (not 60KB of repeated `X` chars).
#
# Baseline: bin/task-dispatch.sh (~45KB, structured bash with comments,
# functions, case statements, logs) — representative of real agent context.
#
# Expected: ratio ≈ level (0.3 → ~30% of input lines kept, etc.)
# Prints a Markdown table so results can be pasted into WORK.md.
#
# Usage:
#   bin/test-compressor.sh                    # use default payload (bin/task-dispatch.sh)
#   bin/test-compressor.sh path/to/file       # use a custom payload
#   bin/test-compressor.sh --verbose          # print first 10 lines of each compressed output

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_FILE="$PROJECT_ROOT/lib/context-compressor.sh"

if [[ ! -f "$LIB_FILE" ]]; then
  echo "ERROR: $LIB_FILE not found" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$LIB_FILE"

# ── args ─────────────────────────────────────────────────────────────────────
VERBOSE="false"
PAYLOAD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE="true"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *)  PAYLOAD="$1"; shift ;;
  esac
done

PAYLOAD="${PAYLOAD:-$PROJECT_ROOT/bin/task-dispatch.sh}"

if [[ ! -f "$PAYLOAD" ]]; then
  echo "ERROR: payload not found: $PAYLOAD" >&2
  exit 1
fi

# ── measure input ────────────────────────────────────────────────────────────
INPUT_BYTES=$(wc -c < "$PAYLOAD" | tr -d ' ')
INPUT_LINES=$(wc -l < "$PAYLOAD" | tr -d ' ')
INPUT_KB=$(echo "scale=1; $INPUT_BYTES / 1024" | bc)
CONTENT=$(cat "$PAYLOAD")

# ── run compression at 3 levels ──────────────────────────────────────────────
echo "Phase 7.3 — Context Compressor Sanity Test"
echo "============================================"
echo "Payload:       $PAYLOAD"
echo "Input size:    ${INPUT_KB} KB, $INPUT_LINES lines, $INPUT_BYTES bytes"
echo ""

printf "| Level | Label  | Out lines | Out bytes | Out KB | Line ratio | Byte ratio |\n"
printf "|-------|--------|-----------|-----------|--------|------------|------------|\n"

RESULTS_DIR="$PROJECT_ROOT/.orchestration/compressor-test"
mkdir -p "$RESULTS_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)

for pair in "0.3:light" "0.5:medium" "0.7:heavy"; do
  LEVEL="${pair%%:*}"
  LABEL="${pair##*:}"

  OUT_FILE="$RESULTS_DIR/${TS}-$LABEL.txt"
  compress_summary "$CONTENT" "$LEVEL" > "$OUT_FILE" 2>&1 || true

  OUT_BYTES=$(wc -c < "$OUT_FILE" | tr -d ' ')
  OUT_LINES=$(wc -l < "$OUT_FILE" | tr -d ' ')
  OUT_KB=$(echo "scale=1; $OUT_BYTES / 1024" | bc)

  # ratios (guard against div-by-zero)
  if [[ "$INPUT_LINES" -gt 0 ]]; then
    LINE_RATIO=$(echo "scale=3; $OUT_LINES / $INPUT_LINES" | bc)
  else
    LINE_RATIO="n/a"
  fi
  if [[ "$INPUT_BYTES" -gt 0 ]]; then
    BYTE_RATIO=$(echo "scale=3; $OUT_BYTES / $INPUT_BYTES" | bc)
  else
    BYTE_RATIO="n/a"
  fi

  printf "| %-5s | %-6s | %9s | %9s | %6s | %10s | %10s |\n" \
    "$LEVEL" "$LABEL" "$OUT_LINES" "$OUT_BYTES" "$OUT_KB" "$LINE_RATIO" "$BYTE_RATIO"

  if [[ "$VERBOSE" == "true" ]]; then
    echo ""
    echo "--- first 10 lines of $LABEL ($LEVEL) ---"
    head -10 "$OUT_FILE"
    echo "--- end preview ---"
    echo ""
  fi
done

echo ""
echo "Results saved: $RESULTS_DIR/${TS}-{light,medium,heavy}.txt"
echo ""
echo "Pass criteria (per WORK.md notes):"
echo "  - line ratios should approximate the requested level"
echo "    (0.3 → ~0.30, 0.5 → ~0.50, 0.7 → ~0.70)"
echo "  - byte ratios typically fall in 0.3–0.7 for structured payloads"
echo "  - summary must end with the ellipsis marker"
echo "    '[CONTENT COMPRESSED: N lines truncated]' when truncation occurred"
echo ""

# ── quick assertion: line ratio sanity ───────────────────────────────────────
FAIL=0
for pair in "0.3:light:0.2:0.4" "0.5:medium:0.4:0.6" "0.7:heavy:0.6:0.8"; do
  LEVEL="${pair%%:*}"
  rest="${pair#*:}"
  LABEL="${rest%%:*}"
  rest="${rest#*:}"
  LO="${rest%%:*}"
  HI="${rest##*:}"

  OUT_FILE="$RESULTS_DIR/${TS}-$LABEL.txt"
  OUT_LINES=$(wc -l < "$OUT_FILE" | tr -d ' ')
  LINE_RATIO=$(echo "scale=3; $OUT_LINES / $INPUT_LINES" | bc)

  IN_BAND=$(echo "$LINE_RATIO >= $LO && $LINE_RATIO <= $HI" | bc -l)
  if [[ "$IN_BAND" -eq 1 ]]; then
    printf "  ✓ %s: line ratio %s in [%s, %s]\n" "$LABEL" "$LINE_RATIO" "$LO" "$HI"
  else
    printf "  ✗ %s: line ratio %s OUT of [%s, %s]\n" "$LABEL" "$LINE_RATIO" "$LO" "$HI"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS — compressor behaves as expected on structured payload."
  exit 0
else
  echo "FAIL — $FAIL level(s) out of expected band. Inspect output files above."
  exit 1
fi

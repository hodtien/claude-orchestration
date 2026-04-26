#!/usr/bin/env bash
# run-all-tests.sh -- discover and run all bin/test-*.sh suites, aggregate results.
# bash 3.2 compatible: no associative arrays, mapfile, |&, or namerefs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── flag parsing ──────────────────────────────────────────────────────────────
OPT_JSON=0
OPT_FAIL_FAST=0
OPT_QUIET=0
OPT_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)      OPT_JSON=1; shift ;;
    --fail-fast) OPT_FAIL_FAST=1; shift ;;
    --quiet)     OPT_QUIET=1; shift ;;
    --filter)    OPT_FILTER="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── runtime helpers ───────────────────────────────────────────────────────────
now_s() {
  python3 -c "import time; print(time.time())" 2>/dev/null || date +%s
}

now_iso() {
  python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo "unknown"
}

elapsed_s() {
  python3 -c "print(round($2 - $1, 2))" 2>/dev/null || echo "0"
}

# ── suite discovery ───────────────────────────────────────────────────────────
SUITE_LIST=""
for f in $(ls "$SCRIPT_DIR"/test-*.sh 2>/dev/null | sort); do
  base="$(basename "$f")"
  if [ -n "$OPT_FILTER" ]; then
    case "$base" in
      $OPT_FILTER) ;;   # matches — keep
      *) continue ;;    # no match — skip
    esac
  fi
  SUITE_LIST="$SUITE_LIST $f"
done

if [ -z "$SUITE_LIST" ]; then
  echo "No test suites found (filter: ${OPT_FILTER:-none})." >&2
  exit 0
fi

# ── result accumulation (parallel arrays via delimited strings, bash 3.2 safe) ──
SUITE_NAMES=""
SUITE_EXITS=""
SUITE_PASSES=""
SUITE_FAILS=""
SUITE_TIMES=""

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
TOTAL_RUNTIME_S=0
RUN_AT="$(now_iso)"

TMPDIR_RUNNER="$(mktemp -d)"
cleanup_runner() { rm -rf "$TMPDIR_RUNNER"; }
trap cleanup_runner EXIT

# ── run each suite ────────────────────────────────────────────────────────────
for script in $SUITE_LIST; do
  name="$(basename "$script")"
  outfile="$TMPDIR_RUNNER/${name}.out"

  if [ "$OPT_QUIET" -eq 0 ]; then
    echo ""
    echo "=== Running: $name ==="
  fi

  t_start="$(now_s)"
  exit_code=0

  if [ "$OPT_QUIET" -eq 1 ]; then
    bash "$script" >"$outfile" 2>&1 || exit_code=$?
  else
    bash "$script" 2>&1 | tee "$outfile"
    # tee masks $?; check the captured output's last exit separately
    exit_code="${PIPESTATUS[0]:-0}"
  fi

  t_end="$(now_s)"
  runtime="$(elapsed_s "$t_start" "$t_end")"

  # parse summary line: ALL N TESTS: X PASS, Y FAIL
  summary_line="$(tail -5 "$outfile" | grep -E '^ALL [0-9]+ TESTS:' | tail -1 || true)"
  if [ -n "$summary_line" ]; then
    pass_count="$(echo "$summary_line" | sed -n 's/.*: \([0-9]*\) PASS.*/\1/p')"
    fail_count="$(echo "$summary_line" | sed -n 's/.* \([0-9]*\) FAIL.*/\1/p')"
    pass_count="${pass_count:-0}"
    fail_count="${fail_count:-0}"
  else
    # no summary line means the script crashed
    pass_count=0
    fail_count=1
  fi

  SUITE_NAMES="$SUITE_NAMES|$name"
  SUITE_EXITS="$SUITE_EXITS|$exit_code"
  SUITE_PASSES="$SUITE_PASSES|$pass_count"
  SUITE_FAILS="$SUITE_FAILS|$fail_count"
  SUITE_TIMES="$SUITE_TIMES|$runtime"

  TOTAL_PASS=$((TOTAL_PASS + pass_count))
  TOTAL_FAIL=$((TOTAL_FAIL + fail_count))
  TOTAL_SUITES=$((TOTAL_SUITES + 1))
  TOTAL_RUNTIME_S="$(python3 -c "print(round($TOTAL_RUNTIME_S + $runtime, 2))" 2>/dev/null || echo "$TOTAL_RUNTIME_S")"

  if [ "$exit_code" -eq 0 ]; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    if [ "$OPT_FAIL_FAST" -eq 1 ]; then
      echo ""
      echo "FAIL-FAST: $name failed (exit $exit_code). Stopping." >&2
      break
    fi
  fi
done

# ── summary table ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
printf "%-38s  %5s  %5s  %7s\n" "Suite" "Pass" "Fail" "Time(s)"
echo "──────────────────────────────────────────────────────────────────"

# split parallel arrays (strip leading delimiter)
IFS='|' read -r -a _names  <<< "${SUITE_NAMES#|}"
IFS='|' read -r -a _passes <<< "${SUITE_PASSES#|}"
IFS='|' read -r -a _fails  <<< "${SUITE_FAILS#|}"
IFS='|' read -r -a _times  <<< "${SUITE_TIMES#|}"
IFS='|' read -r -a _exits  <<< "${SUITE_EXITS#|}"

i=0
while [ "$i" -lt "${#_names[@]}" ]; do
  n="${_names[$i]}"
  p="${_passes[$i]}"
  f="${_fails[$i]}"
  t="${_times[$i]}"
  e="${_exits[$i]}"
  status_tag=""
  if [ "$e" -ne 0 ]; then status_tag=" [FAIL]"; fi
  printf "%-38s  %5s  %5s  %7s%s\n" "$n" "$p" "$f" "$t" "$status_tag"
  i=$((i + 1))
done

echo "──────────────────────────────────────────────────────────────────"
printf "%-38s  %5s  %5s  %7s\n" "TOTAL ($TOTAL_SUITES suites)" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_RUNTIME_S"
echo "══════════════════════════════════════════════════════════════════"

if [ "$TOTAL_FAIL" -eq 0 ] && [ "$FAILED_SUITES" -eq 0 ]; then
  echo "ALL $TOTAL_SUITES SUITES PASSED."
else
  echo "FAILED: $FAILED_SUITES suite(s) — $TOTAL_FAIL test(s) failed."
fi

# ── JSON output ───────────────────────────────────────────────────────────────
if [ "$OPT_JSON" -eq 1 ]; then
  echo ""
  python3 - "$RUN_AT" "$TOTAL_SUITES" "$PASSED_SUITES" "$FAILED_SUITES" \
               "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_RUNTIME_S" \
               "${SUITE_NAMES#|}" "${SUITE_EXITS#|}" \
               "${SUITE_PASSES#|}" "${SUITE_FAILS#|}" "${SUITE_TIMES#|}" <<'PYEOF'
import json, sys
run_at         = sys.argv[1]
total_suites   = int(sys.argv[2])
passed_suites  = int(sys.argv[3])
failed_suites  = int(sys.argv[4])
total_pass     = int(sys.argv[5])
total_fail     = int(sys.argv[6])
total_runtime  = float(sys.argv[7])
names   = sys.argv[8].split("|") if sys.argv[8] else []
exits   = sys.argv[9].split("|") if sys.argv[9] else []
passes  = sys.argv[10].split("|") if sys.argv[10] else []
fails   = sys.argv[11].split("|") if sys.argv[11] else []
times   = sys.argv[12].split("|") if sys.argv[12] else []

suites = []
for i in range(len(names)):
    if not names[i]:
        continue
    suites.append({
        "name":      names[i],
        "exit_code": int(exits[i])   if i < len(exits)   else 1,
        "pass":      int(passes[i])  if i < len(passes)  else 0,
        "fail":      int(fails[i])   if i < len(fails)   else 1,
        "runtime_s": float(times[i]) if i < len(times)   else 0.0,
    })

print(json.dumps({
    "total_suites":    total_suites,
    "passed_suites":   passed_suites,
    "failed_suites":   failed_suites,
    "total_pass":      total_pass,
    "total_fail":      total_fail,
    "total_runtime_s": total_runtime,
    "suites":          suites,
    "run_at":          run_at,
}, indent=2))
PYEOF
fi

# ── exit code ─────────────────────────────────────────────────────────────────
if [ "$FAILED_SUITES" -gt 0 ] || [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

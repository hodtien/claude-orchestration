#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
TTY=0; [ -t 1 ] && TTY=1
usage(){ cat <<'EOF'
Usage:
  task-diff.sh <task-id>
  task-diff.sh <task-id> v1 v2
  task-diff.sh <file-a> <file-b>
  task-diff.sh <task-id> --summary
  task-diff.sh <task-id> --review
  task-diff.sh --batch <batch-id>
EOF
}
vfile(){ case "$2" in current) echo "$RESULTS_DIR/$1.out";; v[0-9]*) echo "$RESULTS_DIR/$1.$2.out";; *) echo "[task-diff] invalid version: $2" >&2; return 1;; esac; }
mkdiff(){ local a="$1" b="$2" out rc
  if command -v diff >/dev/null 2>&1; then
    set +e; out="$(diff -u "$a" "$b")"; rc=$?; set -e; [ "$rc" -le 1 ] || return "$rc"; printf '%s' "$out"
  else
    python3 - "$a" "$b" <<'PY'
import difflib, pathlib, sys
a=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines(True)
b=pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines(True)
sys.stdout.writelines(difflib.unified_diff(a,b,fromfile=sys.argv[1],tofile=sys.argv[2],n=3))
PY
  fi
}
counts(){ awk '/^\+[^+]/ {a++} /^-[^-]/ {r++} END{printf "%d %d",a+0,r+0}' <<<"$1"; }
paint(){ [ "$TTY" -eq 1 ] || { printf '%s\n' "$1"; return; }
  awk 'BEGIN{g="\033[32m";r="\033[31m";c="\033[36m";h="\033[90m";x="\033[0m"}
  /^\+\+\+|^---/{print h $0 x;next} /^@@/{print c $0 x;next}
  /^\+/{print g $0 x;next} /^-/{print r $0 x;next} {print}' <<<"$1"
}
show(){ local label="$1" a="$2" b="$3" summary="${4:-0}" out add rem
  [ -f "$a" ] || { echo "[task-diff] missing file: $a" >&2; return 1; }
  [ -f "$b" ] || { echo "[task-diff] missing file: $b" >&2; return 1; }
  out="$(mkdiff "$a" "$b")"; read -r add rem <<<"$(counts "$out")"
  if [ "$summary" -eq 1 ]; then echo "Changes: +$add lines added, -$rem lines removed"; return 0; fi
  echo "Diff: $label"; printf '%s\n' "=================================================="
  [ -n "$out" ] && paint "$out" || echo "[task-diff] no changes"
  printf '%s\n' "=================================================="
  echo "Changes: +$add lines added, -$rem lines removed"
}
batch(){ local bid="$1" f base tid found=0
  echo "Result Diffs Summary (batch: $bid)"
  [ -d "$RESULTS_DIR" ] || { echo "  no results directory"; return 0; }
  while IFS= read -r tid; do
    found=1
    if [ -f "$RESULTS_DIR/$tid.v1.out" ] && [ -f "$RESULTS_DIR/$tid.out" ]; then
      read -r add rem <<<"$(counts "$(mkdiff "$RESULTS_DIR/$tid.v1.out" "$RESULTS_DIR/$tid.out")")"
      echo "  $tid: +$add lines, -$rem lines  (revised)"
    else
      echo "  $tid: no revisions"
    fi
  done < <(
    for f in "$RESULTS_DIR"/*.out; do
      [ -f "$f" ] || continue; base="$(basename "$f")"
      tid="$(sed -E 's/\.review\.out$//; s/\.v[0-9]+\.out$//; s/\.out$//' <<<"$base")"
      [[ "$tid" == "$bid"* ]] && echo "$tid"
    done | sort -u
  )
  [ "$found" -eq 1 ] || echo "  no matching tasks"
}
[ $# -gt 0 ] || { usage; exit 1; }
if [ "$1" = "--batch" ]; then [ $# -eq 2 ] || { usage; exit 1; }; batch "$2"; exit 0; fi
if [ $# -eq 2 ] && [ -f "$1" ] && [ -f "$2" ]; then show "$1 vs $2" "$1" "$2"; exit 0; fi
tid="$1"
case "${2:-}" in
  "") [ $# -eq 1 ] || { usage; exit 1; }
      [ -f "$RESULTS_DIR/$tid.v1.out" ] || { echo "[task-diff] no revisions found for $tid"; exit 0; }
      show "$tid  (v1 -> current)" "$RESULTS_DIR/$tid.v1.out" "$RESULTS_DIR/$tid.out" ;;
  --summary) [ $# -eq 2 ] || { usage; exit 1; }
      [ -f "$RESULTS_DIR/$tid.v1.out" ] || { echo "[task-diff] no revisions found for $tid"; exit 0; }
      show "$tid  (v1 -> current)" "$RESULTS_DIR/$tid.v1.out" "$RESULTS_DIR/$tid.out" 1 ;;
  --review) [ $# -eq 2 ] || { usage; exit 1; }
      show "$tid  (main -> review)" "$RESULTS_DIR/$tid.out" "$RESULTS_DIR/$tid.review.out" ;;
  *) [ $# -eq 3 ] || { usage; exit 1; }
      show "$tid  ($2 -> $3)" "$(vfile "$tid" "$2")" "$(vfile "$tid" "$3")" ;;
esac

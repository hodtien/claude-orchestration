#!/usr/bin/env bash
# consensus-vote.sh — Weighted voting logic for Consensus Engine

# bash 3.x (macOS default) doesn't support associative arrays.
# Define no-op stubs so callers don't fail with "command not found".
#
# NOTE: These stubs intentionally return safe defaults (never fail), so
# callers on bash 3.2 see a "neutral" consensus path (default weight,
# no winner, empty merge) and naturally fall through to first_success.
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    get_weight()        { echo "1.0"; }
    compute_score()     { echo "1.0"; }
    find_winner()       { echo ""; }
    consensus_merge()    { echo "0.0"; echo ""; }
    return 0 2>/dev/null || exit 0
fi

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

# Agent weights for voting — keys match real agent names from config/models.yaml
declare -A AGENT_WEIGHTS=(
    ["cc/claude-sonnet-4-6"]=2.0
    ["cc/claude-opus-4-6"]=2.5
    ["gh/gpt-5.3-codex"]=2.0
    ["gemini-pro"]=2.0
    ["oc-high"]=2.0
    ["oc-medium"]=1.5
    ["minimax-code"]=1.5
    ["cc/claude-haiku-4-5"]=1.0
    ["gh/claude-haiku-4-5"]=1.0
    ["gemini-flash"]=1.0
    [default]=1.0
)

# Default weight
DEFAULT_WEIGHT=1.0

# Get weight for an agent
get_weight() {
    local agent="${1:?agent required}"
    echo "${AGENT_WEIGHTS[$agent]:-$DEFAULT_WEIGHT}"
}

# Compute weighted score
compute_score() {
    local agent="$1"
    local confidence="$2"

    local weight
    weight=$(get_weight "$agent")
    echo "$(echo "$weight * $confidence" | bc -l 2>/dev/null || echo "$DEFAULT_WEIGHT")"
}

# Find winning position
find_winner() {
    local positions_json="${1:?positions_json required}"

    local max_score=0
    local winner=""

    # Parse JSON array of positions — use process substitution to avoid subshell bug
    while IFS= read -r pos; do
        local agent confidence position
        agent=$(echo "$pos" | jq -r '.agent_id')
        confidence=$(echo "$pos" | jq -r '.confidence')
        position=$(echo "$pos" | jq -r '.position')

        local score
        score=$(compute_score "$agent" "$confidence")

        # Compare floats
        local cmp
        cmp=$(echo "$score > $max_score" | bc -l 2>/dev/null || echo "0")
        if [ "$cmp" = "1" ]; then
            max_score="$score"
            winner="$position"
        fi
    done < <(echo "$positions_json" | jq -r '.[] | @json' 2>/dev/null)

    echo "$winner"
}

# Consensus merge — cluster candidates by Jaccard similarity, pick longest
# output from the largest cluster.
#
# Input: candidates_json = [{"agent_id","output","confidence"}, ...]
# Output (stdout): two lines:
#   <consensus_score>  (avg pairwise Jaccard within winning cluster)
#   <winner_output_text>
#
# SIM_THRESHOLD env var overrides default threshold (0.3).
# Lower threshold = more forgiving clustering.
consensus_merge() {
 local candidates_json="${1:?candidates_json required}"
 python3 - "$candidates_json" <<'PYEOF'
import sys, json, re, os

candidates = json.loads(sys.argv[1])
THRESHOLD = float(os.environ.get("SIM_THRESHOLD", "0.3"))

if not candidates:
    print("0.0")
    print("")
    sys.exit(0)

def tokenize(text):
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return {t for t in text.split() if len(t) >= 3}

def jaccard(a, b):
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)

tokens = [tokenize(c.get("output", "")) for c in candidates]
n = len(candidates)

# Pairwise similarity
sim = [[0.0] * n for _ in range(n)]
for i in range(n):
    for j in range(i + 1, n):
        s = jaccard(tokens[i], tokens[j])
        sim[i][j] = sim[j][i] = s

# Single-link clustering via union-find
parent = list(range(n))
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb:
        parent[ra] = rb

for i in range(n):
    for j in range(i + 1, n):
        if sim[i][j] >= THRESHOLD:
            union(i, j)

# Group by cluster root
clusters = {}
for i in range(n):
    r = find(i)
    clusters.setdefault(r, []).append(i)

# Winning cluster: largest by size, tiebreak by longest output
def longest_len(members):
    return max(len(candidates[m].get("output", "")) for m in members)

winning_members = max(clusters.values(), key=lambda m: (len(m), longest_len(m)))

# Winner: longest output in winning cluster (first on tie)
winner_idx = max(winning_members, key=lambda m: (len(candidates[m].get("output", "")), -m))
winner_text = candidates[winner_idx].get("output", "")

# Score: avg pairwise Jaccard within winning cluster
if len(winning_members) < 2:
    score = 0.0
else:
    pairs = [sim[winning_members[i]][winning_members[j]]
             for i in range(len(winning_members))
             for j in range(i + 1, len(winning_members))]
    score = sum(pairs) / len(pairs) if pairs else 0.0

print(f"{score:.3f}")
print(winner_text)
PYEOF
}

# Main — only run dispatch when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
      weight)    shift; get_weight "$@" ;;
      score)     shift; compute_score "$@" ;;
      winner)    shift; find_winner "$@" ;;
      merge)     shift; consensus_merge "$@" ;;
      *)         echo "Usage: $0 weight|score|winner|merge" >&2; exit 1 ;;
  esac
fi

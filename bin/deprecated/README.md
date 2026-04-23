# Deprecated scripts

These scripts were moved here during the Apr 22 refactor because:
- No other script / doc / skill references them
- They appear to be prototypes or experimental features not wired into the main flow

**They still work if you run them directly.** They're not deleted — just removed from the
main `bin/` to reduce noise.

## Review policy

If after ~1 month of living here a script hasn't been restored / referenced,
it's safe to delete entirely. Re-check with:

```bash
for f in bin/deprecated/*.sh; do
  name=$(basename "$f")
  refs=$(grep -rl "$name" ../../../ --include='*.sh' --include='*.md' --include='*.mjs' 2>/dev/null | grep -v 'deprecated' | wc -l)
  echo "$refs refs: $name"
done
```

## What was moved (2026-04-22)

| Script | Reason |
|---|---|
| consensus-trigger.sh | Part of Phase 4 consensus engine; never wired in |
| decompose.sh | Used by neither task-dispatch nor any skill |
| intent-detect.sh | Superseded by `lib/intent-verifier.sh` |
| learn-from-batch.sh | Uses `lib/learning-engine.sh`; never called |
| orch-trace.sh | Debug tracing tool; not used |
| parallel-run.sh | Functionality merged into `agent-parallel.sh` |
| provenance-{blame,commit,query}.sh | Provenance chain scripts; never wired |
| routing-advisor.sh | Design doc tool; never called |
| share-learnings.sh | Phase 5 feature; never wired |
| speculation-detector.sh | Part of Phase 4 speculation layer |
| sprint-manager.sh | CLAUDE.md says no sprint ceremonies |
| style-*.sh | Style memory scripts; never wired |
| task-dlq.sh | DLQ handled inside task-dispatch.sh |
| task-{gen,init,new}.sh | 3 scripts doing the same thing; unused |
| transfer-context.sh | Not referenced |

## Why not delete?

Solo-dev project — some of these might come back when wiring Phase 4/5 features
into `task-dispatch.sh`. Keeping the code local saves git-archaeology.

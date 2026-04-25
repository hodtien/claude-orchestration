---
id: long-task-001
agent: copilot
task_type: implement_feature
priority: high
estimated_tokens: 8000
---

# Task: Implement Distributed Cache Layer

## Objective
Implement a distributed cache layer for the orchestration system to reduce
redundant LLM calls and improve response latency across parallel agent runs.
This involves designing the cache schema, implementing cache read/write
primitives, wiring them into the dispatch pipeline, and adding observability.

## Background and Motivation
The current architecture issues a fresh LLM call for every subtask regardless
of whether an identical or semantically equivalent call was made recently.
Profiling shows that up to 40% of calls in large batch runs are near-duplicates.
A shared cache keyed on a normalized prompt hash can eliminate most of this
redundancy, cutting both cost and latency significantly.

The cache must be safe for concurrent access from multiple agent processes,
must not introduce correctness regressions, and must degrade gracefully when
unavailable (i.e., cache misses fall back to live LLM calls transparently).

## Context
- Runtime: bash orchestration layer + Python helper scripts
- Storage backend: local filesystem (first milestone), Redis (second milestone)
- Agents involved: copilot, codex, opus, flash
- Related modules: lib/task-dispatch.sh, lib/llm-bridge.sh, lib/trace-query.sh
- Existing test harness: bin/test-*.sh pattern, PASS/FAIL counters

## Deliverables

### Section 1: Cache Schema Design
Design and document the on-disk cache schema.

- Define directory layout under `.orchestration/cache/`
- Key format: SHA-256 of normalized prompt (model + stripped whitespace)
- Value format: JSON envelope with cached response and metadata
- Implement `cache_key()` bash function in `lib/cache.sh`
- Implement `cache_read()` — returns cached value or exits 1 on miss
- Implement `cache_write()` — atomic write via tmp-file + mv
- Unit tests for all three functions in `bin/test-cache.sh`

### Section 2: LLM Bridge Integration
Wire cache read/write into the existing LLM call path.

- Modify `lib/llm-bridge.sh`: before issuing call, attempt `cache_read()`
- On hit: log cache hit to trace, return cached response, skip LLM call
- On miss: issue LLM call, then `cache_write()` response before returning
- Add `CACHE_ENABLED` env flag (default true); when false, bypass entirely
- Add `CACHE_TTL_SECONDS` env flag (default 3600)
- Preserve existing function signatures — no breaking changes
- All existing llm-bridge tests must continue to pass

### Section 3: Observability and Metrics
Add cache hit/miss metrics to the dashboard.

- Emit structured log lines for cache hits and misses
- Extend `lib/trace-query.sh` with `cache_hit_rate()` aggregation function
- Extend `bin/budget-dashboard.sh` to display cache hit rate as percentage
- Add `bin/test-cache-metrics.sh` with at least 10 assertions
- Document metric format in `docs/CACHE_METRICS.md`

## Constraints
- Must implement in pure bash where possible; Python only for JSON parsing
- No external dependencies beyond what is already in the repo
- Cache reads must complete in under 10ms on SSD hardware
- Cache writes must be atomic (no partial reads from concurrent agents)
- Must implement TTL expiry: entries older than TTL seconds are misses
- Must handle concurrent writers without corruption (use lockfile or atomic mv)
- Must not break any existing test in `bin/test-*.sh`
- Compatible with bash 3.2 (macOS) and bash 5+ (Linux)

## Acceptance Criteria
- `bin/test-cache.sh` passes all assertions
- `bin/test-cache-metrics.sh` passes all assertions
- All existing test suites continue to pass
- Cache hit rate observed in integration smoke test
- Budget dashboard displays cache metrics without error
- `CACHE_ENABLED=false` disables cache with zero test regressions

## Implementation Notes
- Use `flock` on Linux; fall back to `mkdir` lock on macOS bash 3.2
- Normalize prompts by stripping leading/trailing whitespace and collapsing
  internal runs of whitespace to single spaces before hashing
- SHA-256 via `shasum -a 256` (macOS) or `sha256sum` (Linux); detect at load
- TTL check: compare cached_at + ttl_seconds against current epoch
- Log all cache operations for debugging

## Testing Strategy
- Unit test each function in isolation with fixture inputs
- Use isolated temp directory to prevent cache interference
- Mock LLM bridge in cache integration tests (no real LLM calls)
- Verify atomicity by spawning concurrent writers in test and checking output

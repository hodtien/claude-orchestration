import { test } from "node:test";
import assert from "node:assert/strict";
import {
  eventTimeMs,
  isRunning,
  isTerminal,
  type TaskEvent
} from "./types.js";

test("isTerminal: succeeded status → true", () => {
  assert.equal(isTerminal({ status: "succeeded" }), true);
});

test("isTerminal: failed/error/exhausted/blocked → true", () => {
  assert.equal(isTerminal({ status: "failed" }), true);
  assert.equal(isTerminal({ outcome: "error" }), true);
  assert.equal(isTerminal({ status: "exhausted" }), true);
  assert.equal(isTerminal({ event: "blocked" }), true);
});

test("isTerminal: running/start → false", () => {
  assert.equal(isTerminal({ status: "running" }), false);
  assert.equal(isTerminal({ event: "start" }), false);
});

test("isTerminal: empty event → false", () => {
  assert.equal(isTerminal({}), false);
});

test("eventTimeMs: ISO ts parses", () => {
  const ms = eventTimeMs({ ts: "2026-04-26T07:32:11Z" });
  assert.equal(ms, Date.parse("2026-04-26T07:32:11Z"));
});

test("eventTimeMs: missing ts → 0", () => {
  assert.equal(eventTimeMs({}), 0);
});

test("eventTimeMs: malformed ts → 0", () => {
  assert.equal(eventTimeMs({ ts: "not-a-date" }), 0);
});

test("eventTimeMs: timestamp fallback", () => {
  const ms = eventTimeMs({ timestamp: "2026-04-26T07:32:11Z" });
  assert.equal(ms, Date.parse("2026-04-26T07:32:11Z"));
});

test("isRunning: fresh start within window → true", () => {
  const now = Date.now();
  const ev: TaskEvent = {
    event: "start",
    ts: new Date(now - 60_000).toISOString()
  };
  assert.equal(isRunning(ev, now), true);
});

test("isRunning: stale start beyond 10min → false", () => {
  const now = Date.now();
  const ev: TaskEvent = {
    event: "start",
    ts: new Date(now - 11 * 60_000).toISOString()
  };
  assert.equal(isRunning(ev, now), false);
});

test("isRunning: terminal status → false", () => {
  const now = Date.now();
  const ev: TaskEvent = {
    status: "succeeded",
    ts: new Date(now - 1000).toISOString()
  };
  assert.equal(isRunning(ev, now), false);
});

test("isRunning: missing ts → false (cannot judge freshness)", () => {
  assert.equal(isRunning({ event: "start" }), false);
});

test("isRunning: status=running fresh → true", () => {
  const now = Date.now();
  const ev: TaskEvent = {
    status: "running",
    ts: new Date(now - 30_000).toISOString()
  };
  assert.equal(isRunning(ev, now), true);
});

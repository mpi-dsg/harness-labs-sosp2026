import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { readLedger, sendMessage } from "../index.mjs";

function ledgerPath() {
  return path.join(mkdtempSync(path.join(tmpdir(), "outbox-test-")), "outbox.jsonl");
}

const MESSAGE = { to: "ops@example.com", body: "disk full", message_id: "m-1" };

test("appends one row per call", () => {
  const file = ledgerPath();
  sendMessage(MESSAGE, { file });
  assert.equal(readLedger(file).length, 1);
});

test("without dedupe, the same logical message duplicates the effect", () => {
  const file = ledgerPath();
  sendMessage(MESSAGE, { file, dedupe: false });
  sendMessage(MESSAGE, { file, dedupe: false });

  const rows = readLedger(file);
  assert.equal(rows.length, 2, "at-least-once delivery duplicates a non-idempotent effect");
  assert.equal(rows[0].message_id, rows[1].message_id);
});

test("with dedupe, replaying the same message_id appends nothing", () => {
  const file = ledgerPath();
  const first = sendMessage(MESSAGE, { file, dedupe: true });
  const second = sendMessage(MESSAGE, { file, dedupe: true });

  assert.equal(readLedger(file).length, 1, "the idempotency key collapses the retry");
  assert.equal(second.deduplicated, true);
  assert.equal(first.deduplicated, false);
  assert.equal(second.sent_at, first.sent_at, "the original result is returned, not a new one");
});

test("dedupe keys on message_id, so a fresh id per attempt fixes nothing", () => {
  const file = ledgerPath();
  sendMessage({ ...MESSAGE, message_id: "attempt-1" }, { file, dedupe: true });
  sendMessage({ ...MESSAGE, message_id: "attempt-2" }, { file, dedupe: true });

  assert.equal(readLedger(file).length, 2, "the key must be stable across retries to mean anything");
});

test("distinct messages are not collapsed", () => {
  const file = ledgerPath();
  sendMessage(MESSAGE, { file, dedupe: true });
  sendMessage({ ...MESSAGE, message_id: "m-2", body: "disk still full" }, { file, dedupe: true });
  assert.equal(readLedger(file).length, 2);
});

test("rejects missing and blank fields", () => {
  const file = ledgerPath();
  for (const bad of [
    { ...MESSAGE, to: "" },
    { ...MESSAGE, body: "   " },
    { ...MESSAGE, message_id: undefined },
    {},
  ]) {
    assert.throws(() => sendMessage(bad, { file }), /required/);
  }
  assert.equal(readLedger(file).length, 0, "a rejected call must not commit an effect");
});

test("rejects oversized fields", () => {
  const file = ledgerPath();
  assert.throws(() => sendMessage({ ...MESSAGE, body: "x".repeat(2001) }, { file }), /at most/);
});

test("a torn final line does not break the reader", () => {
  const file = ledgerPath();
  sendMessage(MESSAGE, { file });
  writeFileSync(file, `${readFileSync(file, "utf8")}{"message_id":"m-2","to":`, "utf8");

  const rows = readLedger(file);
  assert.equal(rows.length, 1, "a crash mid-append leaves a torn line; skip it, keep the rest");
});

test("a missing ledger reads as empty", () => {
  assert.deepEqual(readLedger(path.join(tmpdir(), "outbox-does-not-exist.jsonl")), []);
});

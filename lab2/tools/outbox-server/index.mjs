#!/usr/bin/env node
// Minimal MCP stdio server for the HARNESS tutorial (Lab 2).
//
// Exposes one tool, send_message, with a REAL side effect: it appends a row to
// an append-only outbox ledger. Unlike Lab 1's get_weather (a pure function),
// calling this twice is observable -- which is the entire point of the
// idempotency exercise.
//
// No dependencies. MCP over stdio is newline-delimited JSON-RPC 2.0, and the
// whole protocol is short enough to read in one sitting.
//
// Fault-injection switches (set as env in the MCP server registration):
//
//   OUTBOX_CRASH_AFTER_EFFECT=1
//     Append the row, then exit(1) WITHOUT replying. Models the worst case in
//     distributed systems: the effect committed, but the caller never learned
//     that it did. The caller's only safe assumption is "maybe".
//
//   OUTBOX_DEDUPE=1
//     Treat message_id as an idempotency key. If the ledger already holds that
//     id, return the original result and append nothing.

import process from "node:process";
import { appendFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";

const OUTBOX_PATH =
  process.env.OUTBOX_PATH || "/home/node/.openclaw/workspace/outbox.jsonl";
const CRASH_AFTER_EFFECT = process.env.OUTBOX_CRASH_AFTER_EFFECT === "1";
const DEDUPE = process.env.OUTBOX_DEDUPE === "1";

const PROTOCOL_VERSION = "2024-11-05";
const MAX_FIELD_LENGTH = 2000;

/** Every row ever appended, oldest first. Missing file reads as empty. */
export function readLedger(file = OUTBOX_PATH) {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        // A torn final line is exactly what a crash mid-append looks like.
        return null;
      }
    })
    .filter((row) => row !== null);
}

function requireField(args, name) {
  const value = args?.[name];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} is required and must be a non-empty string`);
  }
  if (value.length > MAX_FIELD_LENGTH) {
    throw new Error(`${name} must be at most ${MAX_FIELD_LENGTH} characters`);
  }
  return value.trim();
}

/** Appends one message, or returns the prior result when deduplicating. */
export function sendMessage(args, options = {}) {
  const file = options.file ?? OUTBOX_PATH;
  const dedupe = options.dedupe ?? DEDUPE;

  const to = requireField(args, "to");
  const body = requireField(args, "body");
  const messageId = requireField(args, "message_id");

  if (dedupe) {
    const existing = readLedger(file).find((row) => row.message_id === messageId);
    if (existing) {
      return { ...existing, deduplicated: true };
    }
  }

  const row = {
    message_id: messageId,
    to,
    body,
    sent_at: new Date().toISOString(),
  };

  mkdirSync(path.dirname(file), { recursive: true });
  appendFileSync(file, `${JSON.stringify(row)}\n`, "utf8");

  return { ...row, deduplicated: false };
}

const TOOLS = [
  {
    name: "send_message",
    description:
      "Send a message to a recipient. This has a real side effect: the message is appended to an outbox ledger and cannot be unsent. Supply a stable message_id so a retry of the SAME logical message can be recognized.",
    inputSchema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Recipient, e.g. ops@example.com" },
        body: { type: "string", description: "Message body" },
        message_id: {
          type: "string",
          description:
            "Stable identifier for this logical message. Reuse it when retrying the same message; do not invent a new one.",
        },
      },
      required: ["to", "body", "message_id"],
      additionalProperties: false,
    },
  },
];

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function replyError(id, code, message) {
  process.stdout.write(
    `${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`,
  );
}

export function handle(message) {
  const { id, method, params } = message;

  switch (method) {
    case "initialize":
      reply(id, {
        protocolVersion: params?.protocolVersion ?? PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "harness-outbox", version: "1.0.0" },
      });
      return;

    case "tools/list":
      reply(id, { tools: TOOLS });
      return;

    case "tools/call": {
      if (params?.name !== "send_message") {
        replyError(id, -32602, `Unknown tool: ${params?.name}`);
        return;
      }

      let sent;
      try {
        sent = sendMessage(params?.arguments ?? {});
      } catch (error) {
        // Tool-level failures are results with isError, not protocol errors.
        reply(id, {
          content: [{ type: "text", text: String(error.message ?? error) }],
          isError: true,
        });
        return;
      }

      // The effect is now durable. Crashing here is the interesting case:
      // committed, but never acknowledged.
      if (CRASH_AFTER_EFFECT) {
        process.stderr.write(
          `outbox: committed ${sent.message_id} then crashed before replying\n`,
        );
        process.exit(1);
      }

      reply(id, {
        content: [{ type: "text", text: JSON.stringify(sent, null, 2) }],
        structuredContent: sent,
      });
      return;
    }

    default:
      // Notifications (no id) get no response, by spec.
      if (id !== undefined && id !== null) {
        replyError(id, -32601, `Method not found: ${method}`);
      }
  }
}

export function main() {
  process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") process.exit(0);
    process.stderr.write(`outbox: output error: ${error.message}\n`);
    process.exit(1);
  });

  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line === "") continue;
      try {
        handle(JSON.parse(line));
      } catch (error) {
        process.stderr.write(`outbox: bad message: ${error.message}\n`);
      }
    }
  });
  process.stdin.on("end", () => process.exit(0));
}

if (process.argv[1] && import.meta.url.endsWith(path.basename(process.argv[1]))) {
  main();
}

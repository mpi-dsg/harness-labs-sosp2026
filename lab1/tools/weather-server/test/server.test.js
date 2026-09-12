import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { closeSync, openSync } from "node:fs";
import { copyFile, mkdtemp, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const SERVER_DIR = path.dirname(fileURLToPath(new URL("../index.js", import.meta.url)));
const ENTRY_POINTS = ["index.js", "index.bundle.mjs"];

async function withClient(entryPoint, callback, cwd = SERVER_DIR) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [entryPoint],
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "weather-server-test", version: "1.0.0" });

  await client.connect(transport);
  try {
    return await callback(client);
  } finally {
    await client.close();
  }
}

function parseTextResult(result) {
  assert.equal(result.isError, undefined);
  assert.equal(result.content.length, 1);
  assert.equal(result.content[0].type, "text");
  return JSON.parse(result.content[0].text);
}

for (const entryPoint of ENTRY_POINTS) {
  test(`${entryPoint} exposes structured, normalized weather data`, async () => {
    await withClient(entryPoint, async (client) => {
      const tools = await client.listTools();
      assert.deepEqual(tools.tools.map(({ name }) => name), ["get_weather"]);

      const result = await client.callTool({
        name: "get_weather",
        arguments: { city: "  PRAGUE  " },
      });
      const weather = parseTextResult(result);

      assert.deepEqual(weather, {
        city: "Prague",
        temperature_c: 18,
        conditions: "partly cloudy",
        humidity_pct: 62,
        supported: true,
        source: "canned",
      });
      assert.deepEqual(result.structuredContent, weather);
    });
  });

  test(`${entryPoint} rejects empty and oversized city names`, async () => {
    await withClient(entryPoint, async (client) => {
      for (const city of ["", "   ", "x".repeat(201)]) {
        const result = await client.callTool({
          name: "get_weather",
          arguments: { city },
        });
        assert.equal(result.isError, true, `expected ${JSON.stringify(city)} to fail`);
      }
    });
  });

  test(`${entryPoint} handles prototype-chain names without corrupting output`, async () => {
    await withClient(entryPoint, async (client) => {
      for (const city of ["constructor", "__proto__"]) {
        const result = await client.callTool({
          name: "get_weather",
          arguments: { city },
        });
        assert.deepEqual(parseTextResult(result), {
          city,
          temperature_c: 20,
          conditions: "clear",
          humidity_pct: 55,
          supported: false,
          source: "fallback",
        });
      }
    });
  });
}

test("the bundled entry point works without installed dependencies", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "weather-bundle-test-"));
  try {
    await copyFile(
      path.join(SERVER_DIR, "index.bundle.mjs"),
      path.join(directory, "index.bundle.mjs"),
    );
    await withClient("index.bundle.mjs", async (client) => {
      const result = await client.callTool({
        name: "get_weather",
        arguments: { city: "Berlin" },
      });
      assert.equal(parseTextResult(result).temperature_c, 16);
    }, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("malformed protocol input is reported on stderr", async () => {
  const child = spawn(process.execPath, ["index.js"], {
    cwd: SERVER_DIR,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  child.stdin.end("not-json\n");
  const [exitCode] = await new Promise((resolve) => child.once("exit", (...args) => resolve(args)));

  assert.equal(exitCode, 0);
  assert.match(stderr, /MCP protocol error:/);
});

test("the package executable starts when invoked through an installed symlink", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "weather-bin-test-"));
  const executable = path.join(directory, "harness-weather-server");
  try {
    await symlink(path.join(SERVER_DIR, "index.bundle.mjs"), executable);
    const child = spawn(executable, [], { stdio: ["pipe", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    child.stdin.end("not-json\n");
    const [exitCode] = await new Promise((resolve) =>
      child.once("exit", (...args) => resolve(args)),
    );

    assert.equal(exitCode, 0);
    assert.match(stderr, /MCP protocol error:/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("a closed response pipe is treated as a normal peer disconnect", async () => {
  const child = spawn(process.execPath, ["index.js"], {
    cwd: SERVER_DIR,
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdout.destroy();
  child.stdin.end(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "closed-pipe-test", version: "1.0.0" },
    },
  })}\n`);

  const [exitCode] = await new Promise((resolve) => child.once("exit", (...args) => resolve(args)));
  assert.equal(exitCode, 0);
});

test("non-EPIPE response failures exit nonzero with a sanitized error", async () => {
  const readOnlyOutput = openSync("/dev/null", "r");
  const child = spawn(process.execPath, ["index.js"], {
    cwd: SERVER_DIR,
    stdio: ["pipe", readOnlyOutput, "pipe"],
  });
  closeSync(readOnlyOutput);
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.stdin.end(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "bad-output-test", version: "1.0.0" },
    },
  })}\n`);

  const [exitCode] = await new Promise((resolve) => child.once("exit", (...args) => resolve(args)));
  assert.notEqual(exitCode, 0);
  assert.match(stderr, /MCP output error:/);
  assert.doesNotMatch(stderr, /node_modules|index\.js:/);
});

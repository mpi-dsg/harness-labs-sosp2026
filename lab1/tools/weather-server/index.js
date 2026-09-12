#!/usr/bin/env node
// Minimal MCP stdio server for the HARNESS tutorial (Lab 1).
//
// Exposes one tool, get_weather, that returns deterministic canned data. The
// agent runtime launches the bundled entry point as a child process and speaks
// MCP over stdin/stdout.

import process from "node:process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

export const MAX_CITY_LENGTH = 200;

const CITY_INPUT = z
  .string()
  .trim()
  .min(1, "City must not be empty")
  .max(MAX_CITY_LENGTH, `City must be at most ${MAX_CITY_LENGTH} characters`);

const WEATHER_OUTPUT = z
  .object({
    city: z.string().min(1),
    temperature_c: z.number(),
    conditions: z.string().min(1),
    humidity_pct: z.number().int().min(0).max(100),
    supported: z.boolean(),
    source: z.enum(["canned", "fallback"]),
  })
  .strict();

// Map avoids inherited keys such as "constructor" and "__proto__".
const CITIES = new Map([
  ["prague", { city: "Prague", temperature_c: 18, conditions: "partly cloudy", humidity_pct: 62 }],
  ["berlin", { city: "Berlin", temperature_c: 16, conditions: "overcast", humidity_pct: 71 }],
  ["copenhagen", { city: "Copenhagen", temperature_c: 14, conditions: "light rain", humidity_pct: 78 }],
  [
    "san francisco",
    { city: "San Francisco", temperature_c: 17, conditions: "fog", humidity_pct: 84 },
  ],
]);

const FALLBACK_WEATHER = Object.freeze({
  temperature_c: 20,
  conditions: "clear",
  humidity_pct: 55,
});

export function getWeather(city) {
  const normalizedCity = CITY_INPUT.parse(city);
  const knownWeather = CITIES.get(normalizedCity.toLowerCase());

  if (knownWeather) {
    return { ...knownWeather, supported: true, source: "canned" };
  }

  return {
    city: normalizedCity,
    ...FALLBACK_WEATHER,
    supported: false,
    source: "fallback",
  };
}

export function createServer() {
  const server = new McpServer({
    name: "harness-weather",
    version: "1.0.0",
  });

  server.server.onerror = (error) => {
    const message = error instanceof Error ? error.message : "Unknown protocol error";
    console.error(`MCP protocol error: ${message}`);
  };

  server.registerTool(
    "get_weather",
    {
      description:
        "Get deterministic canned weather for a city. Unknown cities are explicitly marked as fallback data.",
      inputSchema: { city: CITY_INPUT.describe("City name, e.g. Prague") },
      outputSchema: WEATHER_OUTPUT,
    },
    ({ city }) => {
      const weather = getWeather(city);
      return {
        content: [{ type: "text", text: JSON.stringify(weather, null, 2) }],
        structuredContent: weather,
      };
    },
  );

  return server;
}

function installOutputErrorHandler() {
  process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") {
      process.exit(0);
    }

    console.error(`MCP output error: ${error.message}`);
    process.exit(1);
  });
}

export async function main() {
  installOutputErrorHandler();
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

const isMainModule =
  process.argv[1] !== undefined && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]);

if (isMainModule) {
  try {
    await main();
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown startup error";
    console.error(`Weather server failed: ${message}`);
    process.exitCode = 1;
  }
}

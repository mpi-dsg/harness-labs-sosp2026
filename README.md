# HARNESS Labs — Starter Repository

Lab environment for the [HARNESS tutorial](https://harness.mpi-dsg.org/) at SOSP 2026:
a pinned [OpenClaw](https://github.com/openclaw/openclaw) agent runtime, a local model
(Ollama), a custom MCP tool, and the policy/sandbox/tracing configs used in the labs.
Everything runs locally. No cloud accounts or API keys.

## Before the tutorial (at home, good network)

Clone this repository, open a terminal at its root, and run the pre-flight:

```sh
git clone https://github.com/mpi-dsg/harness-labs-sosp2026.git
cd harness-labs-sosp2026
./preflight.sh
```

The pre-flight verifies Docker, pulls ~8 GB of digest-pinned images plus the
local model, builds three local images, and writes a validated `.env` with private
permissions. Re-running it preserves a valid gateway token and is safe.
Any additional `.env` settings, such as resource or port overrides, are
preserved.

## Layout

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | Base stack: gateway + CLI (Ollama runs on the host. The containerized one is opt-in via the `container-ollama` profile) |
| `docker-compose.otel.yml` | Overlay: Jaeger (Lab 1, Part 3) |
| `docker-compose.sandbox.yml` | Overlay: Docker socket for sandboxing (Lab 2, Part 2) |
| `Dockerfile` | Gateway image: pinned OpenClaw + Docker CLI built from checksum-pinned source |
| `jaeger/Dockerfile` | Pinned Jaeger image with patched Alpine TLS libraries |
| `sandbox/Dockerfile` | The sandbox image OpenClaw spawns per session |
| `lab1/tools/weather-server/` | The MCP tool you register in Lab 1. Run `index.bundle.mjs` (no npm install) |
| `lab2/policies/` | Tool-policy and sandbox config templates for Lab 2 |
| `lab2/tools/outbox-server/` | Lab 2's MCP tool with a real side effect, dependency-free, one file |
| `scripts/replay-tool-call.sh` | Redeliver one tool call without the model (Lab 2, Exercise 3) |
| `scripts/apply-policy.sh` | Deep-merge policy fragments, validate, and show the effective policy |
| `state/` | Lab-local OpenClaw state (config, sessions, logs). Never touches `~/.openclaw`. |
| `preflight.sh` | Environment check + image/model download |

## Quick smoke test

```sh
docker compose up -d --wait --wait-timeout 120
curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/healthz" && echo ' gateway OK'
```

Lab instructions: [Lab 1](https://harness.mpi-dsg.org/materials/lab1) · [Lab 2](https://harness.mpi-dsg.org/materials/lab2)

## Versions (pinned for reproducibility)

| Component | Version |
|-----------|---------|
| OpenClaw | `docker.io/openclaw/openclaw:2026.7.1` |
| Ollama | host-native (installed by pre-flight). `0.32.0` for the opt-in container fallback. Model `qwen3:4b` |
| Jaeger | `2.19.0` (v2), rebuilt locally as `harness-jaeger:2.19.0` with patched Alpine TLS libs |
| Docker CLI (in gateway image) | `29.6.1`, checksum-pinned source built with Go `1.26.5` |

Image references are pinned by both version and multi-platform manifest digest.

## Applying the Lab 2 policies

The policy files are strict JSON fragments. Deep-merge them at the root of
`state/openclaw.json`. Arrays from the later stage replace earlier arrays. Apply
`restrictive.json`, then `sandbox.json`, and finally `iterated.json`. Validate
the result before restarting the gateway:

```sh
docker compose run --rm openclaw-cli config validate
```

`sandbox.json` isolates filesystem and process tools in a per-session container.
Gateway tools and configured MCP servers still execute in the gateway container.
The `bundle-mcp` allow entry is therefore safe only while the configured bundle
contains trusted servers such as this repository's canned weather server.

The sandbox overlay deliberately mounts the host Docker socket. That grants the
gateway root-equivalent control of the Docker host. Use it only on a disposable
local lab machine. Production deployments need an isolated rootless daemon or a
strictly constrained Docker API proxy.

## Resource overrides

The stack has default CPU, memory, PID, and log-size ceilings. Override them in
the shell when needed, for example `OLLAMA_MEMORY_LIMIT=8g docker compose up -d`.

## Verification

The full gate requires Docker, Node.js 22 or newer, `jq`, and ShellCheck:

```sh
bash tests/run.sh
```

Two end-to-end gates drive the labs against a live stack. Run `./preflight.sh`
first, then:

```sh
bash scripts/e2e.sh        # Lab 1: deploy, register the MCP tool, trace it
bash scripts/e2e-lab2.sh   # Lab 2: policy, sandbox, idempotency
```

`e2e-lab2.sh` needs exactly one model round-trip. Policy, sandbox, and
idempotency are all asserted deterministically, so it does not go flaky on
small-model tool-calling variance.

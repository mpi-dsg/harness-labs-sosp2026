#!/usr/bin/env bash
# End-to-end smoke test for the HARNESS lab environment.
#
# Drives the exact Lab 1 sequence against the validated architecture:
# host-native Ollama for the model, containerized OpenClaw gateway + CLI.
# Run ./preflight.sh first (installs/starts Ollama, pulls images and model).
#
# Emits STEP-OK / STEP-FAIL lines; exits non-zero on first failure.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODEL="${HARNESS_MODEL:-qwen3:4b}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-$(awk -F= '$1 == "OPENCLAW_GATEWAY_PORT" { print $2 }' .env 2>/dev/null)}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

step() { printf 'STEP-OK: %s\n' "$1"; }
die()  { printf 'STEP-FAIL: %s\n' "$1"; exit 1; }
run_cli() { docker compose run --rm -T openclaw-cli "$@"; }

# 1. Host Ollama serving with the model present
curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null || die "host Ollama not serving (run ./preflight.sh)"
step "host Ollama serving"

# The host answering is not the same as a container being able to reach it.
# shellcheck source=scripts/lib/ollama-reach.sh
. "$(dirname "$0")/lib/ollama-reach.sh"
if ! ollama_reachable_from_container; then
  printf 'STEP-FAIL: host Ollama is up but unreachable from a container\n'
  ollama_container_hint
  exit 1
fi
step "Ollama reachable from a container"
ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq -- "$MODEL" || die "model $MODEL missing (run ./preflight.sh)"
step "model $MODEL present"

# 2. Local builds
# Rebuilding needs the network even when every base image is cached: one layer
# runs apt-get and npm install, and that layer misses BuildKit's cache on a
# from-clean rebuild. Verified with `docker build --network=none`, which fails
# there while every earlier layer reports CACHED. So when the image already
# exists and we cannot reach a registry, reuse it rather than fail offline.
# HARNESS_SKIP_BUILD=1 forces the same reuse.
have_image() { docker image inspect "$1" >/dev/null 2>&1; }
registry_reachable() {
  curl -fsS --max-time 5 https://registry-1.docker.io/v2/ >/dev/null 2>&1 \
    || [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://registry-1.docker.io/v2/ 2>/dev/null)" = "401" ]
}

skip_build=0
if [ "${HARNESS_SKIP_BUILD:-0}" = "1" ]; then
  skip_build=1
elif have_image harness-openclaw:2026.7.1 && have_image openclaw-sandbox:bookworm-slim \
     && ! registry_reachable; then
  skip_build=1
  printf 'NOTE: no registry reachable; reusing the built images.\n'
fi

if [ "$skip_build" = "1" ]; then
  have_image harness-openclaw:2026.7.1 || die "cannot skip build: harness-openclaw:2026.7.1 is not built"
  have_image openclaw-sandbox:bookworm-slim || die "cannot skip build: openclaw-sandbox:bookworm-slim is not built"
  step "build harness-openclaw (reused)"
  step "build sandbox image (reused)"
else
  docker compose build openclaw-gateway >/dev/null 2>&1 || die "build harness-openclaw"
  step "build harness-openclaw"
  docker build -q -t openclaw-sandbox:bookworm-slim sandbox/ >/dev/null || die "build sandbox image"
  step "build sandbox image"
fi

# 3. Gateway up (unconfigured start is allowed by --allow-unconfigured)
docker compose up -d --wait --wait-timeout 180 openclaw-gateway >/dev/null 2>&1 || die "start gateway"
step "start gateway"
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null || die "healthz"
step "healthz 200"

# 4. Onboard against host Ollama
run_cli onboard --non-interactive --auth-choice ollama \
  --custom-base-url http://host.docker.internal:11434 --custom-model-id "$MODEL" \
  --accept-risk >/tmp/harness-e2e-onboard.log 2>&1 || die "onboard (see /tmp/harness-e2e-onboard.log)"
step "onboard non-interactive (ollama/$MODEL)"

# Local-model settings the labs rely on: generous provider timeout, no
# thinking channel (small models), keep the coding tool profile from onboard.
run_cli config set models.providers.ollama.timeoutSeconds 300 >/dev/null 2>&1 || die "config timeoutSeconds"
run_cli config set agents.defaults.thinkingDefault off >/dev/null 2>&1 || die "config thinkingDefault"
step "local-model config applied"

# onboard rewrites contextWindow to the model maximum (262144 for qwen3:4b).
# Pin it before anything talks to the model, or the first `doctor --fix` loads a
# 256k context and takes the machine with it.
./scripts/pin-context-window.sh >/dev/null 2>&1 || die "pin context window"
step "context window pinned"

# Onboard/config writes may trigger a gateway auto-restart. Retry readiness.
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/readyz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "readyz (gateway did not become ready in 60s)"
step "readyz 200"

# 5. Warm the model (first inference loads weights; avoid an agent timeout)
ollama run "$MODEL" "Say only: pong" >/dev/null 2>&1 || die "model warm-up"
step "model warmed"

# 6. First message through the agent (fresh session: small local models are
# sensitive to accumulated context; a session that has once deliberated
# confusedly stays unreliable)
reply=$(run_cli agent --session-key e2e-pong --message "Reply with exactly the word: pong" 2>&1) \
  || die "agent message failed: $(printf '%s' "$reply" | tail -3 | tr '\n' ' ')"
printf '%s' "$reply" | grep -qi "pong" || die "unexpected reply: $(printf '%s' "$reply" | tail -3 | tr '\n' ' ')"
step "agent replied"

# 7. Register the weather MCP server (as attendees do: edit config, hot reload)
python3 - <<'PY' || die "config edit"
import json, pathlib
p = pathlib.Path("state/openclaw.json")
cfg = json.loads(p.read_text())
cfg.setdefault("mcp", {}).setdefault("servers", {})["weather"] = {
    "command": "node",
    "args": ["/home/node/.openclaw/workspace/tools/weather-server/index.bundle.mjs"],
}
p.write_text(json.dumps(cfg, indent=2))
PY
step "weather MCP server registered in config"

# The config watcher does NOT pick up mcp.servers on a hot reload: verified by
# waiting 3 s, 10 s, and 30 s, then reading the gateway log, which never mentions
# the server at all. The agent run then hangs until it is aborted
# (OPENCLAW_DIRECT_ABORT) rather than reporting a missing tool. A restart is the
# only thing that loads it. Lab 1 Part 3 tells attendees to restart for this
# reason; the gate has to do the same or it tests a path nobody walks.
docker compose restart openclaw-gateway >/dev/null 2>&1 \
  || die "could not restart the gateway to load the weather MCP server"
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/readyz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "gateway did not become ready after the MCP restart"

# Re-warm. The restart evicts the model, so the next call pays a ~5 GB reload on
# top of inference and the client aborts it (OPENCLAW_DIRECT_ABORT) before the
# reply lands. Warm first and the same prompt answers in about 130 s.
ollama run "$MODEL" "Say only: pong" >/dev/null 2>&1 || die "model re-warm after restart"
step "gateway restarted; weather server loaded; model re-warmed"

# 8. Weather query through the agent (tool id is weather__get_weather; fresh session)
reply=$(run_cli agent --session-key e2e-weather --message "Use the get_weather tool to check the weather in Prague, then state the temperature in Celsius." 2>&1) \
  || die "weather message failed: $(printf '%s' "$reply" | tail -3 | tr '\n' ' ')"
printf '%s' "$reply" | grep -q "18" || die "no temperature in reply: $(printf '%s' "$reply" | tail -5 | tr '\n' ' ')"
step "agent used weather tool (18 C in reply)"

# 9. Transcript check: the executed tool call must be recorded
# Newest plain transcript. Trajectory files are a separate artifact; a loop with
# -nt avoids parsing ls output.
latest=""
for f in state/agents/*/sessions/*.jsonl; do
  [ -e "$f" ] || continue
  case "$f" in *.trajectory.jsonl) continue ;; esac
  if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then latest="$f"; fi
done
[ -n "$latest" ] || die "no session transcript found under state/agents/*/sessions/"
grep -q '"name": *"weather__get_weather"' "$latest" || grep -q 'weather__get_weather' "$latest" \
  || die "weather__get_weather not found in transcript $latest"
step "transcript records weather__get_weather ($latest)"

# The lookup idiom Lab 1 step 3.1 prints must actually resolve. It did not: the
# key is stored as "sessionKey":"agent:main:e2e-weather", so a pattern anchored
# on a quote before the key ('"e2e-weather"') matches nothing, and the attendee
# gets an empty path with no error. Assert the documented form here.
traj=$(grep -l "agent:main:e2e-weather" state/agents/main/sessions/*.trajectory.jsonl 2>/dev/null | head -1)
[ -n "$traj" ] || die "session lookup by key found nothing (Lab 1 step 3.1 idiom is broken)"
[ -f "${traj%.trajectory.jsonl}.jsonl" ] || die "session key resolved to no transcript file"
step "session lookup by key resolves (Lab 1 step 3.1)"

printf 'E2E-PASS: all steps green\n'

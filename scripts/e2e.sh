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
ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq -- "$MODEL" || die "model $MODEL missing (run ./preflight.sh)"
step "model $MODEL present"

# 2. Local builds
docker compose build openclaw-gateway >/dev/null 2>&1 || die "build harness-openclaw"
step "build harness-openclaw"
docker build -q -t openclaw-sandbox:bookworm-slim sandbox/ >/dev/null || die "build sandbox image"
step "build sandbox image"

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
sleep 3  # config watcher debounce + hot reload

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

printf 'E2E-PASS: all steps green\n'

#!/usr/bin/env bash
# End-to-end check for Lab 1 Part 3.3 (tracing with Jaeger).
#
# Kept separate from scripts/e2e.sh because tracing needs a second compose file
# and the step is optional for attendees. It exists because the documented path
# was wrong in three different ways at once and nothing caught it: a config key
# no code reads, a service name that does not exist, and a span name that is
# never emitted. A fix nobody re-runs is a fix that rots.
#
# Emits STEP-OK / STEP-FAIL; exits non-zero on the first failure.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

step() { printf 'STEP-OK: %s\n' "$1"; }
die()  { printf 'STEP-FAIL: %s\n' "$1"; exit 1; }

export COMPOSE_FILE=docker-compose.yml:docker-compose.otel.yml

# shellcheck source=scripts/lib/ollama-reach.sh
. "$(dirname "$0")/lib/ollama-reach.sh"
if ! ollama_reachable_from_container; then
  printf 'STEP-FAIL: host Ollama is up but unreachable from a container\n'
  ollama_container_hint
  exit 1
fi
step "Ollama reachable from a container"

docker compose up -d --wait >/dev/null 2>&1 || die "could not start the stack with the tracing overlay"
step "gateway and Jaeger up"

# The exporter is driven by OTEL_* env, not by OpenClaw config. Assert the
# overlay actually delivers them, because that was the whole bug.
for var in OTEL_SERVICE_NAME OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL; do
  docker compose exec -T openclaw-gateway printenv "$var" >/dev/null 2>&1 \
    || die "$var is not set on the gateway; the overlay did not apply"
done
step "OTEL_* environment delivered to the gateway"

docker compose run --rm -T openclaw-cli plugins enable diagnostics-otel >/dev/null 2>&1 \
  || die "could not enable the diagnostics-otel plugin"
step "diagnostics-otel enabled"

curl -fsS -m 5 "http://127.0.0.1:16686/api/services" >/dev/null 2>&1 \
  || die "Jaeger UI is not answering on 16686"
step "Jaeger API reachable"

count_traces() {
  curl -s -m 10 "http://127.0.0.1:16686/api/traces?service=openclaw-gateway&limit=200" 2>/dev/null \
    | python3 -c 'import sys,json;print(len((json.load(sys.stdin).get("data") or [])))' 2>/dev/null || echo 0
}
before=$(count_traces)

docker compose run --rm -T openclaw-cli agent --session-key "e2e-trace-$(date +%s)" \
  --message "Reply with exactly the word: pong" >/dev/null 2>&1 \
  || die "agent run failed under the tracing overlay"
step "agent replied with tracing enabled"

after=$before
for _ in $(seq 1 12); do
  sleep 3
  after=$(count_traces)
  [ "$after" -gt "$before" ] && break
done
[ "$after" -gt "$before" ] \
  || die "no new trace reached Jaeger (was $before, now $after); the exporter is not wired"
step "a new trace reached Jaeger ($before -> $after)"

# The lab names these spans. If the runtime stops emitting one, the lab is wrong
# again and an attendee is the one who finds out.
# Jaeger indexes operations behind trace ingestion, so the list is short for a
# few seconds after a trace lands. Checking once here failed with only two spans
# visible while the rest were still being indexed. Poll instead.
read_ops() {
  curl -s -m 10 "http://127.0.0.1:16686/api/services/openclaw-gateway/operations" \
    | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin).get("data") or []))' 2>/dev/null
}
ops=""
for _ in $(seq 1 20); do
  ops=$(read_ops)
  printf '%s' "$ops" | grep -q "openclaw.run" \
    && printf '%s' "$ops" | grep -q "openclaw.model.call" && break
  sleep 3
done
for span in openclaw.run openclaw.model.call; do
  printf '%s' "$ops" | grep -q "$span" || die "documented span $span is not recorded after 60s (have: $ops)"
done
step "documented spans present"

# And the claim the lab makes about what is ABSENT.
if printf '%s' "$ops" | grep -q "openclaw.tool.execution"; then
  die "openclaw.tool.execution now exists; Lab 1 Part 3.3 says it does not"
fi
step "no tool-execution span, as the lab states"

printf 'E2E-TRACING-PASS: all steps green\n'

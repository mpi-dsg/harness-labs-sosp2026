#!/usr/bin/env bash
# End-to-end gate for Lab 2 (policies, sandbox, idempotency).
#
# Companion to scripts/e2e.sh, which covers Lab 1. Run Lab 1's e2e first: this
# assumes an onboarded agent with the weather MCP server registered.
#
# Design note: only ONE step needs the model. Policy resolution, sandbox
# enforcement, and the idempotency exercise are all driven deterministically --
# through the tool-policy log, `sandbox explain`, and direct JSON-RPC against
# the tool server. That keeps this gate fast and keeps it from going flaky on
# small-model tool-calling variance.
#
# Emits STEP-OK / STEP-FAIL; exits non-zero on first failure.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

COMPOSE_BASE=(-f docker-compose.yml)
COMPOSE_SANDBOX=(-f docker-compose.yml -f docker-compose.sandbox.yml)
# The sandbox container prefix is openclaw-sbx-, NOT the image name
# openclaw-sandbox. Filtering on the image name silently matches nothing.
SBX_PREFIX=openclaw-sbx
OUTBOX=state/workspace/outbox.jsonl
OUTBOX_SERVER=/home/node/.openclaw/workspace/lab2-tools/outbox-server/index.mjs

step() { printf 'STEP-OK: %s\n' "$1"; }
die()  { printf 'STEP-FAIL: %s\n' "$1"; exit 1; }
run_cli() { docker compose "${COMPOSE_BASE[@]}" run --rm -T openclaw-cli "$@"; }

backup=$(mktemp)
cp state/openclaw.json "$backup" 2>/dev/null || die "no state/openclaw.json (run scripts/e2e.sh first)"
restore() { cp "$backup" state/openclaw.json 2>/dev/null; rm -f "$backup"; }
trap restore EXIT

rows() { wc -l < "$OUTBOX" 2>/dev/null | tr -d ' ' || echo 0; }

# Merge a policy fragment the way the lab tells attendees to.
apply_policy() {
  python3 - "$1" <<'PY' || die "policy merge failed"
import json, pathlib, sys
cfg = json.loads(pathlib.Path("state/openclaw.json").read_text())
frag = json.loads(pathlib.Path(sys.argv[1]).read_text())
def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = v
merge(cfg, frag)
pathlib.Path("state/openclaw.json").write_text(json.dumps(cfg, indent=2))
PY
  sleep 4  # config watcher debounce + hot reload
}

# ---------------------------------------------------------------- Part 0
docker compose "${COMPOSE_BASE[@]}" up -d --wait --wait-timeout 180 openclaw-gateway >/dev/null 2>&1 \
  || die "gateway did not start"
step "gateway healthy"

# Same precondition as Lab 1. Without it, a dropped Docker route surfaces as
# "FailoverError: the provider endpoint is unreachable" attached to whatever
# step happened to run first, which reads like a policy bug and is not one.
# shellcheck source=scripts/lib/ollama-reach.sh
. "$(dirname "$0")/lib/ollama-reach.sh"
if ! ollama_reachable_from_container; then
  printf 'STEP-FAIL: host Ollama is up but unreachable from a container\n'
  ollama_container_hint
  exit 1
fi
step "Ollama reachable from a container"

# ---------------------------------------------------------------- Part 1: policy
apply_policy lab2/policies/restrictive.json
step "restrictive policy applied"

# One model round-trip. This must come FIRST: the tool-policy lines are only
# emitted when a session builds its tool list, so there is nothing to assert
# against until an agent turn has happened.
reply=$(run_cli agent --session-key "e2e-lab2-$(date +%s)" \
  --message "Use the get_weather tool: what's the weather in Berlin?" 2>&1) \
  || die "agent failed under restrictive policy: $(printf '%s' "$reply" | tail -3 | tr '\n' ' ')"
printf '%s' "$reply" | grep -q "16" \
  || die "no Berlin temperature in reply: $(printf '%s' "$reply" | tail -5 | tr '\n' ' ')"
step "agent still answers, and the MCP tool still works (16 C)"

# Now assert on what the policy actually stripped. This is the regression that
# broke Lab 2: `allow` replaces the profile baseline, so profile+allow resolved
# to an empty tool set and nothing was callable.
stripped=$(docker compose "${COMPOSE_BASE[@]}" logs openclaw-gateway 2>&1 \
  | grep 'tool-policy' | grep 'removed' | tail -3)
[ -n "$stripped" ] || die "no tool-policy 'removed' lines after an agent turn"

printf '%s' "$stripped" | grep -q 'sessions_send' \
  && die "policy stripped sessions_send -- the agent cannot reply"
printf '%s' "$stripped" | grep -q 'weather__get_weather' \
  && die "policy stripped the MCP tool -- bundle-mcp needs alsoAllow, not allow"
step "policy keeps sessions_send and the MCP tool"

# Denied families must actually be gone.
for tool in exec write web_fetch; do
  printf '%s' "$stripped" | grep -q "\\b${tool}\\b" \
    || die "expected $tool to be stripped by the policy"
done
step "exec, write, and web_fetch stripped"

# ---------------------------------------------------------------- Part 2: sandbox
# HARNESS_SKIP_BUILD=1 reuses an already-built sandbox image. Useful when
# re-running the gate, and a way out when the local Docker builder is unhappy.
if [ "${HARNESS_SKIP_BUILD:-0}" = "1" ]; then
  docker image inspect openclaw-sandbox:bookworm-slim >/dev/null 2>&1 \
    || die "HARNESS_SKIP_BUILD=1 but openclaw-sandbox:bookworm-slim is not built"
else
  docker build -q -t openclaw-sandbox:bookworm-slim sandbox/ >/dev/null || die "build sandbox image"
fi
step "sandbox image present"

apply_policy lab2/policies/sandbox.json
explain=$(docker compose "${COMPOSE_SANDBOX[@]}" run --rm -T openclaw-cli sandbox explain 2>&1) \
  || die "sandbox explain failed"
printf '%s' "$explain" | grep -q 'mode: all' || die "sandbox mode is not 'all'"
printf '%s' "$explain" | grep -q 'scope: session' || die "sandbox scope is not 'session'"
step "sandbox active: mode=all scope=session"

# num_ctx must stay pinned. Onboarding records the model maximum (262144 for
# qwen3:4b) and `doctor --fix` copies contextWindow into num_ctx, which overrides
# OLLAMA_CONTEXT_LENGTH on every request and makes Ollama load a 256k context --
# measured at ~42 GB, mostly on CPU. It does not error; it swaps.
# contextWindow itself is deliberately NOT checked: it is OpenClaw's prompt
# budget, and lowering it to 16384 makes every call fail the overflow precheck.
check_context_pin() {
  python3 - <<'PYCHK'
import json, pathlib, sys
cfg = json.loads(pathlib.Path("state/openclaw.json").read_text())
models = cfg.get("models", {}).get("providers", {}).get("ollama", {}).get("models", [])
bad = [
    (m.get("id"), m.get("contextWindow"), (m.get("params") or {}).get("num_ctx"))
    for m in models
    if ((m.get("params") or {}).get("num_ctx") or 0) > 16384
]
for mid, cw, nc in bad:
    print(f"  {mid}: contextWindow={cw} num_ctx={nc}", file=sys.stderr)
raise SystemExit(1 if bad else 0)
PYCHK
}

check_context_pin || die "context window unpinned; run scripts/pin-context-window.sh"
step "context window pinned at or below 16384"

# `doctor --fix` copies contextWindow into num_ctx, so it UNDOES this pin. That is
# not a bug we can configure away: contextWindow has to stay large for the prompt
# to fit at all (see the header of scripts/pin-context-window.sh). So the contract
# is "re-pin after doctor --fix", and this asserts that re-pinning works, which is
# what an attendee who runs `doctor --fix` mid-lab actually needs.
run_cli doctor --fix >/dev/null 2>&1 || true
if ! check_context_pin 2>/dev/null; then
  ./scripts/pin-context-window.sh >/dev/null 2>&1 \
    || die "doctor --fix unpinned num_ctx and re-pinning failed"
  check_context_pin || die "doctor --fix unpinned num_ctx and the re-pin did not take"
  step "doctor --fix unpins num_ctx (expected); re-pinning restores it"
else
  step "doctor --fix left the pin alone"
fi

# A sandboxed call must actually START A CONTAINER. Asserting on `sandbox explain`
# alone passed for weeks while every sandboxed call failed with "mounts denied",
# because explain reports configuration, not execution.
docker ps -aq --filter "name=$SBX_PREFIX" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
sbx_reply=$(docker compose "${COMPOSE_SANDBOX[@]}" run --rm -T openclaw-cli agent \
  --session-key "e2e-sbx-$(date +%s)" \
  --message "Use your exec tool to run: touch /etc/harness-probe && echo created ; report the exact output or error" 2>&1) || true

if docker compose "${COMPOSE_SANDBOX[@]}" logs --since 10m openclaw-gateway 2>&1 | grep -qi "mounts denied"; then
  die "sandbox bind mount denied -- HARNESS_STATE_DIR path alignment is not in effect"
fi
step "no mounts-denied from the sandbox backend"

if ! docker ps -a --filter "name=$SBX_PREFIX" --format '{{.Names}}' | grep -q .; then
  die "no $SBX_PREFIX container was created -- the sandbox never ran"
fi
step "a sandbox container actually ran"

if printf '%s' "$sbx_reply" | grep -qiE "read-only|permission denied"; then
  step "read-only root enforced inside the sandbox"
else
  printf 'STEP-WARN: sandbox ran but the read-only probe was inconclusive\n'
fi

# ---------------------------------------------------------------- Part 3: idempotency
rm -f "$OUTBOX"
ARGS='{"to":"ops@example.com","body":"disk full","message_id":"m-e2e-1"}'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}'

call_outbox() {  # $1 = env assignments as "K=V K=V"
  local envs=() kv
  for kv in $1; do envs+=(-e "$kv"); done
  printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_message","arguments":%s}}\n' \
    "$INIT" "$ARGS" \
    | docker compose "${COMPOSE_BASE[@]}" run --rm -T "${envs[@]}" \
        --entrypoint node openclaw-cli "$OUTBOX_SERVER" 2>/dev/null
}

out=$(call_outbox "OUTBOX_DEDUPE=0")
printf '%s' "$out" | grep -q '"id":2' || die "outbox server did not reply to a normal call"
[ "$(rows)" = "1" ] || die "expected 1 ledger row after one call, got $(rows)"
step "side effect committed: 1 row"

# At-least-once: the identical request arrives again.
call_outbox "OUTBOX_DEDUPE=0" >/dev/null
[ "$(rows)" = "2" ] || die "expected 2 rows after a naive replay, got $(rows)"
step "naive replay duplicates the effect: 2 rows"

# Crash after the effect commits, before acknowledging it.
rm -f "$OUTBOX"
out=$(call_outbox "OUTBOX_CRASH_AFTER_EFFECT=1")
printf '%s' "$out" | grep -q '"id":2' && die "server replied despite the crash switch"
[ "$(rows)" = "1" ] || die "crash must still leave the committed effect, got $(rows) rows"
step "crash after effect: committed but unacknowledged"

# Idempotency key collapses the retry.
rm -f "$OUTBOX"
call_outbox "OUTBOX_DEDUPE=1" >/dev/null
call_outbox "OUTBOX_DEDUPE=1" >/dev/null
call_outbox "OUTBOX_DEDUPE=1" >/dev/null
[ "$(rows)" = "1" ] || die "dedupe must collapse 3 identical calls to 1 row, got $(rows)"
step "idempotency key holds: 3 calls, 1 row"

# A fresh key per attempt is not idempotency.
rm -f "$OUTBOX"
ARGS='{"to":"ops@example.com","body":"disk full","message_id":"attempt-1"}'
call_outbox "OUTBOX_DEDUPE=1" >/dev/null
ARGS='{"to":"ops@example.com","body":"disk full","message_id":"attempt-2"}'
call_outbox "OUTBOX_DEDUPE=1" >/dev/null
[ "$(rows)" = "2" ] || die "a new key per attempt must NOT deduplicate, got $(rows) rows"
step "fresh key per attempt does not deduplicate: 2 rows"

rm -f "$OUTBOX"
printf 'E2E-LAB2-PASS: all steps green\n'

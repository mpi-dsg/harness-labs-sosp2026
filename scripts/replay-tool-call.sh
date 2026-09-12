#!/usr/bin/env bash
# Replay one MCP tool call directly against a tool server, bypassing the model.
#
# This is what at-least-once redelivery looks like from the tool's side: the
# identical request arrives a second time. Doing it by hand keeps the exercise
# deterministic and fast -- no inference, no waiting for a model to decide to
# retry.
#
# Usage:
#   scripts/replay-tool-call.sh '<arguments-json>' [count]
#
# Example:
#   scripts/replay-tool-call.sh '{"to":"ops@example.com","body":"disk full","message_id":"m-1"}' 2
#
# Env passthrough (set these to change server behavior):
#   OUTBOX_CRASH_AFTER_EFFECT=1   commit the effect, then die before replying
#   OUTBOX_DEDUPE=1               treat message_id as an idempotency key

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ARGS_JSON="${1:?usage: replay-tool-call.sh '<arguments-json>' [count]}"
COUNT="${2:-1}"

SERVER=/home/node/.openclaw/workspace/lab2-tools/outbox-server/index.mjs
TOOL="${REPLAY_TOOL:-send_message}"

if ! printf '%s' "$ARGS_JSON" | python3 -m json.tool >/dev/null 2>&1; then
  printf 'error: arguments must be valid JSON\n' >&2
  exit 1
fi

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"replay","version":"1"}}}'

for i in $(seq 1 "$COUNT"); do
  printf 'replay %s/%s ... ' "$i" "$COUNT"
  call=$(python3 - "$TOOL" "$ARGS_JSON" <<'PY'
import json, sys
print(json.dumps({
    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
    "params": {"name": sys.argv[1], "arguments": json.loads(sys.argv[2])},
}))
PY
  )

  out=$(printf '%s\n%s\n' "$init" "$call" \
    | docker compose run --rm -T \
        -e OUTBOX_CRASH_AFTER_EFFECT="${OUTBOX_CRASH_AFTER_EFFECT:-0}" \
        -e OUTBOX_DEDUPE="${OUTBOX_DEDUPE:-0}" \
        --entrypoint node openclaw-cli "$SERVER" 2>/dev/null)

  if printf '%s' "$out" | grep -q '"id":2'; then
    printf 'replied\n'
  else
    printf 'NO REPLY (server died before acknowledging)\n'
  fi
done

printf '\nLedger now holds %s row(s):\n' "$(wc -l < state/workspace/outbox.jsonl 2>/dev/null | tr -d ' ' || echo 0)"
cat state/workspace/outbox.jsonl 2>/dev/null || printf '(no ledger yet)\n'

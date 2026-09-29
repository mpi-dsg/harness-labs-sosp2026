#!/usr/bin/env bash
# Pin every Ollama model's context window to what the lab actually runs with.
#
# Onboarding records each model's MAXIMUM context window -- 262144 for qwen3:4b.
# Nothing loads that much on its own, so the config looks fine. But
# `openclaw doctor --fix` copies `contextWindow` into `params.num_ctx`, and
# `num_ctx` is sent with every request, where it OVERRIDES the
# OLLAMA_CONTEXT_LENGTH=16384 that preflight.sh set on the Ollama server.
#
# The next message then makes Ollama load the model with a 256k context: about
# 42 GB, most of it spilled to CPU, on a machine this tutorial says needs 8 GB.
# It does not error. It swaps, times out, retries, and looks like a hang.
#
# Pins num_ctx ONLY, and deliberately leaves contextWindow alone. Measured the
# hard way: pinning both breaks every call.
#
# num_ctx is what Ollama allocates, and it is the number that matters for memory:
# 16384 loads qwen3:4b in 5.1 GB, 32768 in 7.6 GB, and the model maximum of
# 262144 extrapolates to about 42 GB, mostly spilled to CPU.
#
# contextWindow is a different thing: OpenClaw's own prompt budget. Do NOT pin it
# down to match. The runtime floors the usable prompt budget at 8,000 tokens
# (MIN_PROMPT_BUDGET_TOKENS) and derives the reserve as contextWindow minus that
# floor, so a small contextWindow yields a budget of exactly 8,000 no matter what
# else is configured. The agent prompt measures ~8,600 tokens, so every call then
# fails the overflow precheck before it is sent. Verified against 16384, 20480,
# and 24576, with agents.defaults.compaction.reserveTokens lowered and the
# gateway restarted: the budget stayed at 8,000 in all of them.
#
# The large contextWindow that onboarding writes is therefore load-bearing, and
# the working combination is exactly: contextWindow left alone, num_ctx pinned.
#
# Consequence: `doctor --fix` copies contextWindow back into num_ctx and undoes
# this. Re-run this script after any `doctor --fix`; scripts/e2e-lab2.sh checks
# that the pin still holds and tells you when it does not.
#
# 16384 is safe but tight, and the tightness is not obvious. Measured on this
# runtime: the agent prompt is ~8,800 tokens and OpenClaw reserves 8,384 more
# for the response, so a 16,384 window leaves 8,000 for a prompt that needs
# 8,778 -- and every call fails the precheck with "Context overflow: prompt too
# large". So this also lowers compaction.reserveTokens to 3072, which is ample
# for the short replies this lab produces and leaves ~13,300 tokens of prompt
# budget. Measured memory: num_ctx 16384 loads qwen3:4b in 5.1 GB; 32768 needs
# 7.6 GB, which does not fit alongside Docker on the 8 GB machine the site
# promises.
#
# Usage:
#   scripts/pin-context-window.sh [SIZE]     # default 16384
#
# Re-run it any time; it is idempotent. Safe to run before or after `doctor --fix`.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SIZE="${1:-16384}"
CONFIG=state/openclaw.json

case "$SIZE" in
  ''|*[!0-9]*) printf 'error: size must be an integer, got %s\n' "$SIZE" >&2; exit 64 ;;
esac
[ -f "$CONFIG" ] || { printf 'error: %s not found -- run Lab 1 Part 1 first\n' "$CONFIG" >&2; exit 1; }

backup="${CONFIG}.before-pin-$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$backup"

if ! python3 - "$CONFIG" "$SIZE" <<'PY'
import json, pathlib, sys

path, size = pathlib.Path(sys.argv[1]), int(sys.argv[2])
config = json.loads(path.read_text())

models = (
    config.get("models", {})
    .get("providers", {})
    .get("ollama", {})
    .get("models", [])
)
if not models:
    print("  no Ollama models in config -- nothing to pin")
    raise SystemExit(0)

for model in models:
    params = model.setdefault("params", {})
    before = params.get("num_ctx")
    params["num_ctx"] = size
    flag = "" if before == size else f"  (was {before})"
    print(f"  {model.get('id', '?'):12} num_ctx={size}{flag}")

path.write_text(json.dumps(config, indent=2) + "\n")
PY
then
  printf 'failed; restoring %s\n' "$backup" >&2
  cp "$backup" "$CONFIG"
  exit 1
fi

# Validate through OpenClaw rather than trusting the edit.
if docker compose run --rm -T openclaw-cli config validate >/dev/null 2>&1; then
  printf '  config validates\n'
else
  printf 'config did NOT validate; restoring %s\n' "$backup" >&2
  cp "$backup" "$CONFIG"
  exit 1
fi

sleep 4  # config watcher debounce
printf '  pinned to %s. doctor --fix is now idempotent for these keys.\n' "$SIZE"

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
# This pins num_ctx ONLY, and deliberately leaves contextWindow alone.
#
# They are different things. num_ctx is what Ollama allocates -- the 42 GB. But
# contextWindow is OpenClaw's own prompt budget, and shrinking it to 16384 makes
# every call fail before it is sent: measured on this runtime, the agent prompt
# is ~8,800 tokens and OpenClaw reserves a further 8,384 for the response, so a
# 16,384 window leaves 8,000 for a prompt that needs 8,778 and the precheck
# refuses with "Context overflow: prompt too large".
#
# Leaving contextWindow high and num_ctx at 16384 is the combination the labs
# were verified against: Ollama loads 5.1 GB, and the ~8.8k prompt fits inside
# 16,384 with room to spare, so nothing is ever truncated in practice.
#
# Consequence worth knowing: `doctor --fix` copies contextWindow back into
# num_ctx, so re-run this script after any `doctor --fix`. scripts/e2e-lab2.sh
# asserts the pin held.
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

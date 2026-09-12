#!/usr/bin/env bash
# Tool-calling reliability trial for lab model selection.
# For each candidate model: N fresh-session weather queries; count how many
# produce the canned 18°C answer (i.e., the MCP tool call actually executed).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TRIALS="${TRIALS:-3}"
read -r -a MODELS <<< "${HARNESS_TRIAL_MODELS:-qwen3:4b qwen3:8b}"
run_cli() { docker compose run --rm -T openclaw-cli "$@"; }

for model in "${MODELS[@]}"; do
  run_cli config set agents.defaults.model "ollama/$model" >/dev/null 2>&1
  ollama run "$model" "Say only: ready" >/dev/null 2>&1   # warm
  pass=0
  for i in $(seq 1 "$TRIALS"); do
    reply=$(run_cli agent --session-key "trial-${model//[:.]/-}-$i" \
      --message "Use the get_weather tool to check the weather in Prague, then state the temperature in Celsius." 2>&1)
    if printf '%s' "$reply" | grep -q "18"; then
      pass=$((pass + 1))
      printf 'TRIAL: %s %d/%d PASS\n' "$model" "$i" "$TRIALS"
    else
      printf 'TRIAL: %s %d/%d FAIL\n' "$model" "$i" "$TRIALS"
    fi
  done
  printf 'MODEL-RESULT: %s %d/%d\n' "$model" "$pass" "$TRIALS"
done
printf 'TRIALS-DONE\n'

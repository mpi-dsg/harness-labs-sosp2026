#!/usr/bin/env bash
# Deep-merge a policy fragment into state/openclaw.json and wait for the reload.
#
# Lab 2 asks you to merge JSON fragments into the live config several times.
# Doing it by hand is the slowest and most error-prone part of the lab, and a
# malformed edit fails in a way that looks like a policy bug. This does the
# merge, validates the result, and waits for the config watcher.
#
# Usage:
#   scripts/apply-policy.sh lab2/policies/restrictive.json
#   scripts/apply-policy.sh lab2/policies/restrictive.json lab2/policies/sandbox.json
#
# Catch-up: passing the fragments for the parts you missed puts you at the end
# of that part. Arrays replace rather than append, matching the lab text, so the
# last fragment naming a key wins.
#
#   end of Part 1   scripts/apply-policy.sh lab2/policies/restrictive.json
#   end of Part 2   scripts/apply-policy.sh lab2/policies/restrictive.json lab2/policies/sandbox.json

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CONFIG=state/openclaw.json

if [ "$#" -eq 0 ]; then
  printf 'usage: %s <fragment.json> [fragment.json ...]\n' "$0" >&2
  exit 64
fi
[ -f "$CONFIG" ] || { printf 'error: %s not found -- run Lab 1 first\n' "$CONFIG" >&2; exit 1; }

for fragment in "$@"; do
  [ -f "$fragment" ] || { printf 'error: no such fragment: %s\n' "$fragment" >&2; exit 1; }
done

backup="${CONFIG}.before-$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$backup"

if ! python3 - "$CONFIG" "$@" <<'PY'
import json, pathlib, sys

config_path = pathlib.Path(sys.argv[1])
config = json.loads(config_path.read_text())


def merge(into, frm):
    """Recursive dict merge. Arrays replace, matching the lab's merge semantics."""
    for key, value in frm.items():
        if isinstance(value, dict) and isinstance(into.get(key), dict):
            merge(into[key], value)
        else:
            into[key] = value


for fragment_path in sys.argv[2:]:
    fragment = json.loads(pathlib.Path(fragment_path).read_text())
    merge(config, fragment)
    print(f"  merged {fragment_path}")

config_path.write_text(json.dumps(config, indent=2) + "\n")
PY
then
  printf 'merge failed; restoring %s\n' "$backup" >&2
  cp "$backup" "$CONFIG"
  exit 1
fi

# Validate through OpenClaw itself rather than trusting the merge.
if docker compose run --rm -T openclaw-cli config validate >/dev/null 2>&1; then
  printf '  config validates\n'
else
  printf 'config did NOT validate; restoring %s\n' "$backup" >&2
  cp "$backup" "$CONFIG"
  exit 1
fi

# mcp/tools/logging changes hot-apply; the watcher debounces first.
sleep 4
printf '  applied. effective policy:\n'
docker compose run --rm -T openclaw-cli sandbox explain 2>/dev/null \
  | sed -n '/Effective sandbox:/,/^$/p' | sed 's/^/    /'
printf '  what the policy stripped:\n'
docker compose logs openclaw-gateway 2>&1 | grep 'tool-policy' | grep 'removed' \
  | tail -2 | sed 's/^/    /' || printf '    (nothing yet -- send one message first)\n'

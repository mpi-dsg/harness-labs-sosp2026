#!/usr/bin/env bash
# Execute the bash blocks of a lab README in document order, exactly as written.
#
# Why this exists: the e2e gates test the machinery, not the instructions. The
# Lab 2 outbox blocker lived in a step the gate deliberately bypasses (it drives
# the MCP server over JSON-RPC instead of registering it), so the gate was green
# while the documented path hung. Three independent audits found it by reading.
# This runs the text an attendee actually types.
#
# Limits, stated honestly: blocks that depend on a manual JSON edit will fail
# here, because the edit lives in a ```json block this does not apply. Those
# failures are expected and are reported separately from real ones.
#
# Usage: scripts/replay-lab-readme.sh ../labs/lab1/README.md [start-block]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

README="${1:?usage: replay-lab-readme.sh <README.md> [start-block]}"
START="${2:-1}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$README" "$WORK" <<'PY'
import re, sys, pathlib
md, out = sys.argv[1], pathlib.Path(sys.argv[2])
text = pathlib.Path(md).read_text()
# Fenced blocks inside a blockquote keep their "> " prefix, which bash reads as
# a redirect. An attendee reading that box types the command without it.
text = re.sub(r'^> ?', '', text, flags=re.M)
blocks = re.findall(r'```bash\n(.*?)```', text, re.S)
kept = 0
for b in blocks:
    b = b.strip()
    if not b:
        continue
    # Skip blocks that are illustrative rather than runnable.
    if re.search(r'<[A-Z_]+>|\.\.\.$|^\s*#\s*(example|illustration)', b, re.M | re.I):
        continue
    kept += 1
    (out / f"{kept:03d}.sh").write_text(b + "\n")
print(kept)
PY

total=$(find "$WORK" -name '*.sh' | wc -l | tr -d ' ')
echo "replaying $total blocks from $README (from #$START)"
echo

pass=0; fail=0; failed_list=""
for f in $(find "$WORK" -name '*.sh' | sort); do
  n=$(basename "$f" .sh); n=${n#0}; n=${n#0}
  [ "$n" -lt "$START" ] && continue
  first=$(head -1 "$f")
  printf '── block %s: %s\n' "$n" "${first:0:96}"
  if timeout 600 bash "$f" >"$WORK/$n.out" 2>&1; then
    pass=$((pass+1)); printf '   OK\n'
  else
    fail=$((fail+1)); failed_list="$failed_list $n"
    printf '   FAILED (exit %s)\n' "$?"
    sed 's/^/      /' "$WORK/$n.out" | tail -4
  fi
done

echo
echo "replay summary: $pass passed, $fail failed"
[ -n "$failed_list" ] && echo "failed blocks:$failed_list"
[ "$fail" -eq 0 ]

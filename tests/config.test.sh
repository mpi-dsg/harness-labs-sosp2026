#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OPENCLAW_IMAGE='docker.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-config-test.XXXXXX")
trap 'trash "$TMP" 2>/dev/null || rm -rf "$TMP"' EXIT

cd "$ROOT"

# The sandbox overlay aligns the container state path with the host one, so it
# needs HARNESS_STATE_DIR. preflight.sh writes it into .env; supply it here so
# the gate does not depend on a developer having run preflight.
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$ROOT/state}"

for policy in lab2/policies/*.json; do
  jq -e 'all(keys[]; startswith("//") | not)' "$policy" >/dev/null
  docker run --rm \
    -e HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/tmp/openclaw \
    -e OPENCLAW_CONFIG_PATH=/config.json \
    -v "$ROOT/$policy:/config.json:ro" \
    --entrypoint node "$OPENCLAW_IMAGE" \
    dist/index.js config validate --json \
    | jq -e '.valid == true' >/dev/null
done

jq -s 'reduce .[] as $item ({}; . * $item)' \
  lab2/policies/restrictive.json \
  lab2/policies/sandbox.json \
  lab2/policies/iterated.json > "$TMP/merged.json"
docker run --rm \
  -e HOME=/home/node \
  -e OPENCLAW_STATE_DIR=/tmp/openclaw \
  -e OPENCLAW_CONFIG_PATH=/config.json \
  -v "$TMP/merged.json:/config.json:ro" \
  --entrypoint node "$OPENCLAW_IMAGE" \
  dist/index.js config validate --json \
  | jq -e '.valid == true' >/dev/null

jq -e '.agents.defaults.sandbox.docker.pidsLimit >= 1' lab2/policies/sandbox.json >/dev/null
jq -e '.agents.defaults.sandbox.workspaceAccess == "ro"' "$TMP/merged.json" >/dev/null
# The policies pair `profile` with `alsoAllow`; `allow` would REPLACE the profile
# baseline rather than extend it, which resolves to an empty tool set.
for policy in lab2/policies/restrictive.json lab2/policies/iterated.json lab2/policies/contained.json; do
  jq -e '.tools | has("allow") | not' "$policy" >/dev/null
  jq -e '.tools.alsoAllow | index("group:sessions") != null' "$policy" >/dev/null
  jq -e '.tools.alsoAllow | index("bundle-mcp") != null' "$policy" >/dev/null
done
jq -e '.tools.alsoAllow | index("read") != null' lab2/policies/iterated.json >/dev/null

# contained.json is the deny-vs-contain demo: exec is deliberately available, so
# the sandbox is what bounds it. group:runtime must NOT be denied, or exec goes
# with it and the exercise proves nothing.
jq -e '.tools.alsoAllow | index("exec") != null' lab2/policies/contained.json >/dev/null
jq -e '.tools.deny | index("group:runtime") == null' lab2/policies/contained.json >/dev/null
jq -e '.tools.deny | index("apply_patch") != null' lab2/policies/iterated.json >/dev/null

docker compose config --quiet
docker compose -f docker-compose.yml -f docker-compose.otel.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.sandbox.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.otel.yml -f docker-compose.sandbox.yml config --quiet

docker compose config --format json > "$TMP/compose.json"
jq -e '.services["openclaw-gateway"].ports[0].host_ip == "127.0.0.1"' "$TMP/compose.json" >/dev/null
jq -e '.services["openclaw-gateway"].cap_drop == ["ALL"]' "$TMP/compose.json" >/dev/null
# Ollama runs natively on the host; the containerized service is an opt-in
# fallback behind the `container-ollama` profile, so it only appears in a
# profile-enabled render.
jq -e '.services.ollama == null' "$TMP/compose.json" >/dev/null
docker compose --profile container-ollama config --format json > "$TMP/compose-ollama.json"
jq -e '.services.ollama.healthcheck != null' "$TMP/compose-ollama.json" >/dev/null
jq -e '.services.ollama.environment.OLLAMA_NO_CLOUD == "true"' "$TMP/compose-ollama.json" >/dev/null
jq -e '.services.ollama.environment.OLLAMA_CONTEXT_LENGTH == "16384"' "$TMP/compose-ollama.json" >/dev/null
jq -e '.services["openclaw-gateway"].command | index("--allow-unconfigured") != null' \
  "$TMP/compose.json" >/dev/null

docker compose -f docker-compose.yml -f docker-compose.otel.yml config --format json > "$TMP/otel.json"
jq -e '.services.jaeger.ports[0].host_ip == "127.0.0.1"' "$TMP/otel.json" >/dev/null
jq -e '.services.jaeger.healthcheck != null' "$TMP/otel.json" >/dev/null
jq -e '.services.jaeger.image == "harness-jaeger:2.19.0"' "$TMP/otel.json" >/dev/null

printf 'configuration tests passed\n'

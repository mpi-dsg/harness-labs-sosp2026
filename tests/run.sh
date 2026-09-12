#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

cd "$ROOT"
bash -n preflight.sh tests/*.sh scripts/*.sh
shellcheck -x preflight.sh tests/*.sh scripts/*.sh
bash tests/preflight.test.sh
bash tests/config.test.sh
docker compose -f docker-compose.yml -f docker-compose.otel.yml build openclaw-gateway jaeger
docker build -t openclaw-sandbox:bookworm-slim sandbox/
bash tests/container-image.test.sh
# Lab 2's outbox server is dependency-free: no bundle, no lockfile, no audit.
# Pass the test file explicitly -- `node --test <dir>` silently matches nothing
# here and exits 0, which would make this step a no-op.
node --test lab2/tools/outbox-server/test/server.test.js

npm --prefix lab1/tools/weather-server run build:check
npm --prefix lab1/tools/weather-server run test:coverage
npm --prefix lab1/tools/weather-server audit
npm --prefix lab1/tools/weather-server audit signatures

printf 'all tests passed\n'

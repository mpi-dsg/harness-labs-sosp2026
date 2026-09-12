#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/harness-preflight-test.XXXXXX")
trap 'trash "$TEST_ROOT" 2>/dev/null || rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    Linux) stat -c '%a' "$1" ;;
    *) fail "unsupported test host for permission checks" ;;
  esac
}

make_fixture() {
  local name=$1
  local fixture="$TEST_ROOT/$name"
  mkdir -p "$fixture/bin"
  cp "$ROOT/preflight.sh" "$fixture/preflight.sh"
  chmod +x "$fixture/preflight.sh"

  cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
case "$*" in
  "--version") echo "Docker version 29.6.1, build test" ;;
  "info") ;;
  "info --format {{.MemTotal}}") echo 8589934592 ;;
  "compose version") echo "Docker Compose version v5.1.3" ;;
  "compose version --short") echo "5.1.3" ;;
  "compose ps --status running --services ollama")
    if [ "${MOCK_OLLAMA_RUNNING:-0}" = 1 ]; then echo ollama; fi
    ;;
  "pull "*)
    if [ "${MOCK_PULL_FAIL:-0}" = 1 ] && [[ "$*" == *openclaw* ]]; then
      exit 42
    fi
    ;;
  "compose exec -T ollama ollama list")
    printf 'NAME ID SIZE MODIFIED\n%s\n' "${MOCK_INSTALLED_MODEL:-qwen3:4b} test 1GB now"
    ;;
  *) ;;
esac
MOCK
  chmod +x "$fixture/bin/docker"

  cat > "$fixture/bin/uname" <<'MOCK'
#!/usr/bin/env bash
echo "${MOCK_UNAME:-Darwin}"
MOCK
  chmod +x "$fixture/bin/uname"

  cat > "$fixture/bin/stat" <<'MOCK'
#!/usr/bin/env bash
if [ "${MOCK_UNAME:-Darwin}" = Darwin ]; then
  echo 1
else
  echo 999
fi
MOCK
  chmod +x "$fixture/bin/stat"

  # Ollama runs natively on the host, so it must be mocked too -- without this
  # the model steps escape the fixture and hit the real daemon.
  cat > "$fixture/bin/ollama" <<'MOCK'
#!/usr/bin/env bash
printf 'ollama %s\n' "$*" >> "${MOCK_LOG:?}"
case "$1" in
  list) printf 'NAME ID SIZE MODIFIED\n%s test 1GB now\n' "${MOCK_INSTALLED_MODEL:-qwen3:4b}" ;;
  pull) [ "${MOCK_MODEL_PULL_FAIL:-0}" = 1 ] && exit 1 ;;
  serve) ;;
  *) ;;
esac
exit 0
MOCK
  chmod +x "$fixture/bin/ollama"

  # Ollama reachability is probed with curl; mock it so the fixture does not
  # depend on whether a real daemon happens to be running on this machine.
  cat > "$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${MOCK_LOG:?}"
case "$*" in
  *11434/api/version*) [ "${MOCK_OLLAMA_SERVING:-1}" = 1 ] || exit 7 ;;
  *) exit 0 ;;
esac
exit 0
MOCK
  chmod +x "$fixture/bin/curl"

  : > "$fixture/mock.log"
  printf '%s\n' "$fixture"
}

run_preflight() {
  local fixture=$1
  shift
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" \
      MOCK_LOG="$fixture/mock.log" \
      MOCK_UNAME="${MOCK_UNAME:-Darwin}" \
      MOCK_PULL_FAIL="${MOCK_PULL_FAIL:-0}" \
      MOCK_MODEL_PULL_FAIL="${MOCK_MODEL_PULL_FAIL:-0}" \
      MOCK_OLLAMA_SERVING="${MOCK_OLLAMA_SERVING:-1}" \
      MOCK_INSTALLED_MODEL="${MOCK_INSTALLED_MODEL:-qwen3:4b}" \
      HARNESS_MODEL="${HARNESS_MODEL:-qwen3:4b}" \
      ./preflight.sh "$@"
  )
}

fixture=$(make_fixture unknown-option)
if run_preflight "$fixture" --checkonly >/dev/null 2>&1; then
  fail "unknown options must be rejected"
fi
[ ! -e "$fixture/.env" ] || fail "an invalid option must not mutate the fixture"

fixture=$(make_fixture docker-gid)
gid=$(run_preflight "$fixture" --docker-gid)
[ "$gid" = 0 ] || fail "Docker Desktop socket must use its container-visible GID (expected 0, got $gid)"

fixture=$(make_fixture linux-docker-gid)
gid=$(MOCK_UNAME=Linux run_preflight "$fixture" --docker-gid)
[ "$gid" = 999 ] || fail "Linux must use the resolved socket GID (expected 999, got $gid)"

fixture=$(make_fixture invalid-socket-path)
if DOCKER_SOCKET_PATH=$'/var/run/docker.sock\nINJECTED=1' \
  run_preflight "$fixture" --docker-gid >/dev/null 2>&1; then
  fail "unsafe Docker socket paths must be rejected"
fi

fixture=$(make_fixture secure-files)
run_preflight "$fixture" >/dev/null
mode=$(file_mode "$fixture/.env")
[ "$mode" = 600 ] || fail ".env must be mode 600 (got $mode)"
mode=$(file_mode "$fixture/state")
[ "$mode" = 700 ] || fail "state must be mode 700 (got $mode)"
grep -Eq '^OPENCLAW_GATEWAY_TOKEN=[0-9a-f]{48}$' "$fixture/.env" || fail "generated token is malformed"

fixture=$(make_fixture placeholder-token)
printf 'OPENCLAW_GATEWAY_TOKEN=replace-me-run-preflight\nDOCKER_GID=0\n' > "$fixture/.env"
run_preflight "$fixture" >/dev/null
grep -Eq '^OPENCLAW_GATEWAY_TOKEN=[0-9a-f]{48}$' "$fixture/.env" || fail "placeholder token was not rotated"
mode=$(file_mode "$fixture/.env")
[ "$mode" = 600 ] || fail "an existing .env must be repaired to mode 600"

fixture=$(make_fixture preserve-settings)
printf '%s\n' \
  'OPENCLAW_GATEWAY_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'OPENCLAW_GATEWAY_PORT=18790' \
  'DOCKER_GID=999' \
  'DOCKER_GID=998' > "$fixture/.env"
run_preflight "$fixture" >/dev/null
grep -Fxq 'OPENCLAW_GATEWAY_PORT=18790' "$fixture/.env" \
  || fail "preflight must preserve unmanaged .env settings"
[ "$(grep -c '^DOCKER_GID=' "$fixture/.env")" -eq 1 ] \
  || fail "preflight must canonicalize duplicate managed settings"

fixture=$(make_fixture pull-failure)
if MOCK_PULL_FAIL=1 run_preflight "$fixture" >/dev/null 2>&1; then
  fail "a failed image pull must fail the preflight"
fi

fixture=$(make_fixture exact-model)
HARNESS_MODEL=qwen3:4 MOCK_INSTALLED_MODEL=qwen3:4b run_preflight "$fixture" >/dev/null
grep -Fq 'ollama pull qwen3:4' "$fixture/mock.log" \
  || fail "model detection must match exact names, not prefixes of an installed model"
grep -Fq 'ollama list' "$fixture/mock.log" \
  || fail "model detection must go through the host Ollama CLI"
grep -Fqv 'compose exec -T ollama' "$fixture/mock.log" \
  || fail "the model must not be pulled through the containerized Ollama service"

printf 'preflight tests passed\n'

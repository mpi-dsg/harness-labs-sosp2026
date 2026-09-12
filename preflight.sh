#!/usr/bin/env bash
# HARNESS tutorial pre-flight (SOSP 2026).

set -euo pipefail
umask 077
cd "$(dirname "$0")"

OPENCLAW_IMAGE="docker.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c"
OLLAMA_IMAGE="docker.io/ollama/ollama:0.32.0@sha256:57f573b47f1f71ebb445789f279fe3e596a8beab182f7cf486db9205bad87c5a"
JAEGER_IMAGE="docker.io/jaegertracing/jaeger:2.19.0@sha256:ede4864215be4cd85bd8c3129a2fea6c5713c5653c7282c429dba123014bc68b"
HARNESS_MODEL="${HARNESS_MODEL:-qwen3:4b}"

FAILED=0
MODE=run

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

usage() {
  cat <<'USAGE'
Usage: ./preflight.sh [--check-only | --docker-gid | --help]

  --check-only  Verify the environment without changing files or containers.
  --docker-gid  Print the Docker socket GID as visible inside Linux containers.
  --help        Show this help.
USAGE
}

parse_arguments() {
  if [ "$#" -gt 1 ]; then
    usage >&2
    return 64
  fi

  case "${1:-}" in
    "") MODE=run ;;
    --check-only) MODE=check ;;
    --docker-gid) MODE=docker-gid ;;
    --help) MODE=help ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      return 64
      ;;
  esac
}

read_env_value() {
  local key=$1
  [ -f .env ] || return 1
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' .env
}

docker_socket_path() {
  local configured_path="${DOCKER_SOCKET_PATH:-}"
  if [ -z "$configured_path" ]; then
    configured_path=$(read_env_value DOCKER_SOCKET_PATH || true)
  fi

  if [ -n "$configured_path" ]; then
    printf '%s\n' "$configured_path"
  elif [[ "${DOCKER_HOST:-}" == unix://* ]]; then
    printf '%s\n' "${DOCKER_HOST#unix://}"
  else
    printf '%s\n' /var/run/docker.sock
  fi
}

docker_gid() {
  local socket_path
  socket_path=$(docker_socket_path)
  [[ "$socket_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
    printf 'Docker socket path must be an absolute path without special characters: %s\n' \
      "$socket_path" >&2
    return 1
  }
  [ -S "$socket_path" ] || {
    printf 'Docker socket not found at %s\n' "$socket_path" >&2
    return 1
  }

  if [[ "${DOCKER_GID_OVERRIDE:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$DOCKER_GID_OVERRIDE"
    return
  fi

  case "$(uname -s)" in
    Darwin)
      # Docker Desktop remaps a bind-mounted Unix socket to root:root in its VM.
      printf '0\n'
      ;;
    Linux) stat -Lc '%g' "$socket_path" ;;
    *)
      printf 'Unsupported host platform; set DOCKER_GID_OVERRIDE explicitly.\n' >&2
      return 1
      ;;
  esac
}

check_environment() {
  echo "== HARNESS pre-flight =="
  echo
  echo "-- Environment checks"

  if command -v docker >/dev/null 2>&1; then
    ok "docker CLI found ($(docker --version | cut -d, -f1))"
  else
    fail "docker CLI not found. Install Docker Desktop or Docker Engine."
  fi

  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is running"
  else
    fail "Docker daemon not reachable. Start Docker and retry."
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "docker compose found ($(docker compose version --short 2>/dev/null || echo '?'))"
  else
    fail "docker compose not found. Update Docker Desktop or install the Compose plugin."
  fi

  for cmd in git curl; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd found"
    else
      fail "$cmd not found"
    fi
  done

  local socket_gid
  if socket_gid=$(docker_gid); then
    ok "Docker socket available (container GID $socket_gid)"
  else
    fail "Docker socket unavailable. Set DOCKER_SOCKET_PATH for rootless Docker/Podman."
  fi

  local avail_gb
  avail_gb=$(df -Pk . | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if [ "${avail_gb:-0}" -ge 10 ]; then
    ok "disk space: ${avail_gb} GB free"
  else
    warn "only ${avail_gb:-0} GB free; 10 GB recommended"
  fi

  local mem_bytes mem_gb
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  [[ "$mem_bytes" =~ ^[0-9]+$ ]] || mem_bytes=0
  mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
  if [ "$mem_gb" -ge 8 ]; then
    ok "Docker memory: ${mem_gb} GB"
  else
    warn "Docker has ${mem_gb} GB memory; 8 GB recommended"
  fi

  if [ "$FAILED" -ne 0 ]; then
    echo
    echo "Fix the FAIL items above, then re-run ./preflight.sh"
    return 1
  fi
}

generate_token() {
  local token
  if command -v openssl >/dev/null 2>&1; then
    token=$(openssl rand -hex 24)
  else
    token=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  [[ "$token" =~ ^[0-9a-f]{48}$ ]] || {
    printf 'Failed to generate a secure gateway token.\n' >&2
    return 1
  }
  printf '%s\n' "$token"
}

existing_token() {
  local count token
  [ -f .env ] || return 1
  count=$(awk -F= '$1 == "OPENCLAW_GATEWAY_TOKEN" { count++ } END { print count + 0 }' .env)
  [ "$count" -eq 1 ] || return 1
  token=$(read_env_value OPENCLAW_GATEWAY_TOKEN)
  [[ "$token" =~ ^[0-9a-f]{48}$ ]] || return 1
  printf '%s\n' "$token"
}

write_environment_file() {
  local token socket_path socket_gid state_dir source_file temporary_file
  if token=$(existing_token); then
    ok "valid gateway token found (keeping it)"
  else
    if [ -f .env ]; then
      warn "invalid or placeholder gateway token replaced"
    fi
    token=$(generate_token)
  fi
  socket_path=$(docker_socket_path)
  socket_gid=$(docker_gid)
  # Absolute HOST path to ./state. The sandbox overlay mounts the state
  # directory at this exact path inside the container so the sibling-container
  # bind mount the runtime requests resolves on the host daemon. Without it,
  # Docker Desktop answers every sandboxed call with "mounts denied".
  state_dir=$(cd state 2>/dev/null && pwd -P) || state_dir="$(pwd -P)/state"
  source_file=/dev/null
  [ ! -f .env ] || source_file=.env
  temporary_file=$(mktemp ./.env.tmp.XXXXXX)

  if ! awk -v token="$token" -v socket_path="$socket_path" -v socket_gid="$socket_gid" \
         -v state_dir="$state_dir" '
    function write_value(key, value) { print key "=" value }
    /^OPENCLAW_GATEWAY_TOKEN=/ {
      if (!token_written) write_value("OPENCLAW_GATEWAY_TOKEN", token)
      token_written = 1
      next
    }
    /^DOCKER_SOCKET_PATH=/ {
      if (!socket_written) write_value("DOCKER_SOCKET_PATH", socket_path)
      socket_written = 1
      next
    }
    /^DOCKER_GID=/ {
      if (!gid_written) write_value("DOCKER_GID", socket_gid)
      gid_written = 1
      next
    }
    /^HARNESS_STATE_DIR=/ {
      if (!state_written) write_value("HARNESS_STATE_DIR", state_dir)
      state_written = 1
      next
    }
    { print }
    END {
      if (!token_written) write_value("OPENCLAW_GATEWAY_TOKEN", token)
      if (!socket_written) write_value("DOCKER_SOCKET_PATH", socket_path)
      if (!gid_written) write_value("DOCKER_GID", socket_gid)
      if (!state_written) write_value("HARNESS_STATE_DIR", state_dir)
    }
  ' "$source_file" > "$temporary_file" \
    || ! chmod 600 "$temporary_file" || ! mv -f "$temporary_file" .env; then
    rm -f "$temporary_file"
    return 1
  fi
  ok "wrote validated .env atomically"
}

prepare_state() {
  install -d -m 700 state state/workspace
  chmod 700 state state/workspace
  ok "state directories ready with private permissions"
}

# Docker Desktop's "credsStore": "desktop" helper can wedge and hang every
# registry operation -- pulls AND the metadata fetches that start a build --
# even for public images. It hangs rather than erroring, so detect it with a
# timed probe and route around it for the rest of this run.
neutralize_docker_credential_helper() {
  grep -q '"credsStore"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null || return 0

  local probe_dir="${TMPDIR:-/tmp}/harness-docker-noauth"
  if timeout 25 docker manifest inspect "$OPENCLAW_IMAGE" >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$probe_dir"
  printf '{}\n' > "$probe_dir/config.json"
  # Keep `docker compose` working: CLI plugins are found via the config dir.
  ln -sfn "$HOME/.docker/cli-plugins" "$probe_dir/cli-plugins" 2>/dev/null || true

  if DOCKER_CONFIG="$probe_dir" timeout 25 docker manifest inspect "$OPENCLAW_IMAGE" >/dev/null 2>&1; then
    export DOCKER_CONFIG="$probe_dir"
    warn "Docker credential helper was hanging; using a neutral DOCKER_CONFIG for this run"
    warn "if you hit this again outside pre-flight: export DOCKER_CONFIG=$probe_dir"
  else
    warn "registry access is slow or unavailable; pulls and builds may take a long time"
  fi
}

pull_images() {
  echo
  echo "-- Pull images (this is the slow part; do it at home)"
  neutralize_docker_credential_helper
  local image images
  images=("$OPENCLAW_IMAGE" "$JAEGER_IMAGE")
  # Containerized Ollama is a Linux/GPU opt-in; macOS gets no GPU in Docker.
  if [ "${HARNESS_CONTAINER_OLLAMA:-0}" = "1" ]; then
    images+=("$OLLAMA_IMAGE")
  fi
  for image in "${images[@]}"; do
    docker pull "$image" >/dev/null
    ok "pulled $image"
  done
}

build_images() {
  echo
  echo "-- Build local images"
  docker compose build --pull openclaw-gateway >/dev/null
  ok "built harness-openclaw (gateway + Docker CLI)"
  docker build --pull -q -t openclaw-sandbox:bookworm-slim sandbox/ >/dev/null
  ok "built openclaw-sandbox:bookworm-slim"
}

setup_host_ollama() {
  echo
  echo "-- Host Ollama (the model runs natively for GPU access)"

  if curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ok "Ollama is serving on 127.0.0.1:11434"
    warn "if you started it yourself, make sure OLLAMA_CONTEXT_LENGTH=16384 is set (OpenClaw prompts exceed the 4k default)"
    return 0
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    case "$(uname -s)" in
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          printf 'Ollama is not installed. Install it now with Homebrew? [Y/n] '
          read -r answer
          case "$answer" in
            n | N | no | NO) fail "Ollama required; install it and re-run"; return 1 ;;
            *) brew install ollama || { fail "brew install ollama failed"; return 1; } ;;
          esac
        else
          fail "Ollama not installed and Homebrew not found. Install from https://ollama.com/download and re-run."
          return 1
        fi
        ;;
      Linux)
        printf 'Ollama is not installed. Install it now (official install script)? [Y/n] '
        read -r answer
        case "$answer" in
          n | N | no | NO) fail "Ollama required; install it and re-run"; return 1 ;;
          *) curl -fsSL https://ollama.com/install.sh | sh || { fail "Ollama install failed"; return 1; } ;;
        esac
        ;;
      *)
        fail "Unsupported platform for automated Ollama install."
        return 1
        ;;
    esac
    ok "Ollama installed"
  fi

  # Start it with a context window large enough for OpenClaw's agent prompt.
  # NOTE: this is a plain background process, not a managed service. It does not
  # survive a reboot or a logout. Attendees who run preflight at home and then
  # restart their laptop will find the containers back and Ollama gone, and the
  # gateway will report "connection refused by the provider endpoint". Re-running
  # this script is the fix, and is safe to repeat.
  nohup env OLLAMA_CONTEXT_LENGTH=16384 OLLAMA_FLASH_ATTENTION=1 \
    ollama serve > state/ollama-host.log 2>&1 &
  disown 2>/dev/null || true
  local i
  for i in $(seq 1 15); do
    curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    [ "$i" -eq 15 ] && { fail "Ollama did not start (see state/ollama-host.log)"; return 1; }
    sleep 1
  done
  ok "Ollama started (context window 16384; log: state/ollama-host.log)"
}

download_model() {
  echo
  echo "-- Download local model ($HARNESS_MODEL)"
  [[ "$HARNESS_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid HARNESS_MODEL name: %s\n' "$HARNESS_MODEL" >&2
    return 1
  }

  if ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -Fxq -- "$HARNESS_MODEL"; then
    ok "model $HARNESS_MODEL already present"
  else
    ollama pull "$HARNESS_MODEL"
    ok "pulled $HARNESS_MODEL"
  fi
}

main() {
  parse_arguments "$@"
  case "$MODE" in
    help) usage; return ;;
    docker-gid) docker_gid; return ;;
  esac

  check_environment
  if [ "$MODE" = check ]; then
    echo
    echo "Environment looks good (check-only mode; nothing changed)."
    return
  fi

  echo
  echo "-- Generate .env"
  write_environment_file
  prepare_state
  pull_images
  build_images
  setup_host_ollama
  download_model

  echo
  echo "== Pre-flight complete =="
  echo
  echo "Next: follow Lab 1. Quick smoke test:"
  echo "  docker compose up -d --wait"
  echo "  curl -fsS http://127.0.0.1:18789/healthz && echo ' gateway OK'"
}

main "$@"

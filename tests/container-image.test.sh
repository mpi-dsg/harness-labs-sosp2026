#!/usr/bin/env bash

set -euo pipefail

IMAGE=${1:-harness-openclaw:2026.7.1}
SANDBOX_IMAGE=${2:-openclaw-sandbox:bookworm-slim}
JAEGER_IMAGE=${3:-harness-jaeger:2.19.0}

docker run --rm --entrypoint bash "$IMAGE" -euo pipefail -c '
  installed_gnutls=$(dpkg-query -W -f="\${Version}" libgnutls30)
  dpkg --compare-versions "$installed_gnutls" ge 3.7.9-2+deb12u7
  node -e "const [major] = process.versions.npm?.split(\".\") ?? []; process.exit(Number(major) >= 12 ? 0 : 1)" 2>/dev/null \
    || [ "$(npm --version | cut -d. -f1)" -ge 12 ]
  pnpm_major=$(pnpm --version | cut -d. -f1)
  pnpm_minor=$(pnpm --version | cut -d. -f2)
  [ "$pnpm_major" -gt 11 ] || { [ "$pnpm_major" -eq 11 ] && [ "$pnpm_minor" -ge 13 ]; }
  docker_go_version=$(grep -aoE "go1\\.26\\.[0-9]+" /usr/local/bin/docker | sort -Vu | tail -1)
  dpkg --compare-versions "${docker_go_version#go}" ge 1.26.5
  [ "$(id -u)" -ne 0 ]
'

docker run --rm --entrypoint sh "$SANDBOX_IMAGE" -eu -c '
  [ "$(id -u)" -eq 10001 ]
  [ "$(id -g)" -eq 10001 ]
  touch /home/sandbox/write-test
'

docker run --rm --entrypoint sh "$JAEGER_IMAGE" -eu -c '
  [ "$(id -u)" -eq 10001 ]
  for package in libcrypto3 libssl3; do
    version=$(apk list --installed "$package" | sed -n \
      "s/^${package}-\\([^ ]*\\).*/\\1/p")
    [ "$(apk version -t "$version" 3.5.7-r0)" != "<" ]
  done
'

printf 'container image tests passed\n'

# HARNESS tutorial gateway image.
#
# Extends the pinned upstream OpenClaw image with the Docker CLI so the sandbox
# backend (Lab 2) can manage sibling containers through the mounted Docker
# socket. Only the CLI is added -- no daemon.

ARG OPENCLAW_BASE_IMAGE=docker.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c
ARG GO_BUILDER_IMAGE=docker.io/library/golang:1.26.8-bookworm@sha256:a688600ca24f8a4d3ca77f95b0dd40704a9fc787c826660eb7ba0b641b8b175d

FROM ${GO_BUILDER_IMAGE} AS docker-cli-builder

WORKDIR /go/src/github.com/docker/cli
ADD --checksum=sha256:74d14dd212b07cd3328989dc6a029dde2ebbe6a878199eaaafad54916f456194 \
    https://codeload.github.com/docker/cli/tar.gz/refs/tags/v29.6.1 /tmp/docker-cli.tar.gz
RUN set -eu; \
    tar -xzf /tmp/docker-cli.tar.gz --strip-components=1; \
    rm -f /tmp/docker-cli.tar.gz; \
    CGO_ENABLED=0 \
      VERSION=29.6.1 \
      GITCOMMIT=8900f1d330cb39e93e16d780a26bff1d7e07ba03 \
      BUILDTIME=2026-06-26T11:37:38Z \
      ./scripts/build/binary; \
    install -D -m 0755 "$(readlink -f build/docker)" /out/docker

FROM ${OPENCLAW_BASE_IMAGE}

USER root

ARG NPM_VERSION=12.0.1
ARG PNPM_VERSION=11.27.1
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends --only-upgrade libgnutls30; \
    rm -rf /var/lib/apt/lists/*; \
    npm install --global "npm@${NPM_VERSION}"; \
    npm cache clean --force; \
    npm pkg set "packageManager=pnpm@${PNPM_VERSION}"; \
    corepack cache clean; \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate; \
    npm --version; \
    pnpm --version

COPY --from=docker-cli-builder /out/docker /usr/local/bin/docker
RUN docker --version

USER node

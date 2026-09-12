# Default OpenClaw sandbox image, vendored from the OpenClaw repository
# (scripts/docker/sandbox/Dockerfile; cache mounts removed for portability).
#
# OpenClaw refuses to run sandboxed sessions until an image with this tag
# exists locally -- it does not silently substitute debian:bookworm-slim,
# because the sandbox write/edit helpers need python3.
#
# Built by preflight.sh as: openclaw-sandbox:bookworm-slim

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

ARG SANDBOX_UID=10001
RUN useradd --create-home --shell /bin/bash --uid "$SANDBOX_UID" --user-group sandbox
USER sandbox
WORKDIR /home/sandbox

CMD ["sleep", "infinity"]

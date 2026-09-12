# Patch the current Jaeger release's Alpine TLS libraries while retaining the
# digest-pinned upstream binary and its non-root runtime identity.
ARG JAEGER_BASE_IMAGE=docker.io/jaegertracing/jaeger:2.19.0@sha256:ede4864215be4cd85bd8c3129a2fea6c5713c5653c7282c429dba123014bc68b
FROM ${JAEGER_BASE_IMAGE}

USER root
RUN apk upgrade --no-cache libcrypto3 libssl3
USER 10001

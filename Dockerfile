# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────────────────────────────────────
# DeepSeek Harness (dsh) Web UI container.
#
# Builds the harness from source, then serves the Web UI. The shipped `dsh web`
# command intentionally refuses `--host 0.0.0.0` and requires a browser-session
# `?token=`; the runtime's reverse proxy (proxy.mjs) exposes the loopback-bound
# server on all interfaces and performs the token exchange transparently:
#
#   browser ──> 0.0.0.0:3080 (proxy.mjs, auto-auth) ──> 127.0.0.1:3081 (dsh web)
#
# The sandbox backend is bubblewrap (`bwrap`); the container seccomp profile
# usually permits it, but if sessions report SANDBOX_UNAVAILABLE run with
# `--security-opt seccomp=unconfined` (or `--privileged`).
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM node:24-bookworm AS builder

# DeepSeek Harness release tag — tracked by Renovate (github-releases).
ARG DSH_REPO=https://github.com/deepseek-ai/deepseek-harness.git
ARG DSH_VERSION=dsh-v0.1.2-alpha.1

# pnpm pinned to the repo's packageManager field — tracked by Renovate (npm).
ARG PNPM_VERSION=11.7.0

# Native-module build deps (esbuild, node-pty, tsdown, etc.).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       ca-certificates \
       curl \
       python3 \
       make \
       g++ \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

WORKDIR /src

# Shallow clone of the pinned ref, install with the committed lockfile, then
# run the full workspace build (lib + client + web frontend).
RUN git clone --depth 1 --branch "${DSH_VERSION}" "${DSH_REPO}" . \
    && pnpm install --frozen-lockfile \
    && pnpm run build

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM node:24-bookworm-slim AS runtime

ARG PNPM_VERSION=11.7.0

# Runtime system dependencies:
#   git              - required by the agent for VCS operations
#   openssh-client   - SSH-based git remotes
#   bubblewrap       - the Linux sandbox backend behind dsh's bash tools
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       openssh-client \
       ca-certificates \
       curl \
       bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user.
RUN groupadd --system dsh && useradd --system --create-home --gid dsh dsh

# Copy the built repository (node_modules, packages, apps, frontend dist).
COPY --from=builder --chown=dsh:dsh /src /app

# The source checkout is not needed at runtime.
RUN rm -rf /app/.git

# pnpm's verify-deps-before-run would otherwise re-run `pnpm install` at
# launch (and abort on the no-TTY modules-dir prompt). The image ships the
# built node_modules; never re-verify at runtime.
RUN printf 'verify-deps-before-run=false\nconfirmModulesPurge=false\n' > /app/.npmrc

# Prewarm the corepack pnpm cache into a shared, writable location so the
# non-root user never downloads pnpm at runtime.
ENV COREPACK_HOME=/opt/corepack
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate \
    && chown -R dsh:dsh /opt/corepack

# Probe the sandbox backend. The build-time result is informational: the
# Dockerfile daemon's seccomp profile governs the build, not the final run.
# Docker's default seccomp profile blocks bwrap's namespace creation; see the
# README for the required `--security-opt seccomp=unconfined` flag.
RUN if bwrap --ro-bind / / true 2>/dev/null; then \
      echo "bubblewrap: functional under this seccomp profile"; \
    else \
      echo "bubblewrap: blocked under the default seccomp profile; run with --security-opt seccomp=unconfined"; \
    fi

ENV NODE_ENV=production
ENV DSH_HOME=/data/.dsh
ENV DSH_PERMISSION_MODE=workspace-write
ENV DSH_TELEMETRY_MODE=DISABLED
ENV DSH_TOOLS_MODE=native

# /data   - DSH_HOME: profiles, sessions, credentials, storage.
# /workspace - mount your project here and select it in the Web UI.
RUN mkdir -p /workspace /data && chown -R dsh:dsh /workspace /data

COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY proxy.mjs /app/proxy.mjs
RUN chmod +x /usr/local/bin/dsh-entrypoint \
    && chown dsh:dsh /app/proxy.mjs

USER dsh
WORKDIR /app

VOLUME ["/data", "/workspace"]

# Public port served by socat; the dsh server itself binds 127.0.0.1:3081.
EXPOSE 3080

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
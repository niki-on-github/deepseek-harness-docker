#!/usr/bin/env bash
set -euo pipefail

PUBLIC_PORT="${PUBLIC_PORT:-3080}"
DSH_PORT="${DSH_PORT:-3081}"

# Warn early if the sandbox backend cannot create namespaces (Docker's default
# seccomp profile blocks it). dsh reports SANDBOX_UNAVAILABLE per session
# otherwise; fail here with a clear remediation instead of at agent time.
if ! bwrap --ro-bind / / true 2>/dev/null; then
  echo "WARNING: bubblewrap is blocked by the container seccomp profile; bash tools will fail with SANDBOX_UNAVAILABLE." >&2
  echo "         Re-run with: --security-opt seccomp=unconfined  (or --privileged)" >&2
fi

# The proxy spawns dsh, relays PUBLIC_PORT -> DSH_PORT, and auto-performs the
# browser-session token exchange so no ?token= is needed. It runs as PID 1 and
# forwards SIGTERM/SIGINT to dsh for a graceful drain.
exec node /app/proxy.mjs
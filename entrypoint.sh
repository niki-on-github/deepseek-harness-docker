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

# The web profile (incl. the baked dsh-mcp-panel bundle) lives in the
# persistent /data volume. Seed it from the image bake on a fresh volume; for
# an existing profile missing the plugin, backfill via `dsh plugin add`
# (needs network). Never clobber a profile the user already has.
WEB_PROFILE="${DSH_HOME:-$HOME/.dsh}/profiles/web"
BOOTSTRAP_PROFILE="/opt/dsh-bootstrap/profiles/web"

if [ ! -f "${WEB_PROFILE}/package.json" ]; then
  if [ -d "${BOOTSTRAP_PROFILE}" ]; then
    echo "dsh: seeding web profile (with dsh-mcp-panel) into ${WEB_PROFILE}"
    mkdir -p "${WEB_PROFILE}"
    cp -a "${BOOTSTRAP_PROFILE}/." "${WEB_PROFILE}/"
  else
    echo "dsh: WARNING: no baked web profile found at ${BOOTSTRAP_PROFILE}" >&2
  fi
elif ! grep -q '"dsh-mcp-panel"' "${WEB_PROFILE}/package.json" 2>/dev/null; then
  echo "dsh: dsh-mcp-panel missing from web profile; installing (needs network)..."
  if DSH_HOME="${DSH_HOME:-$HOME/.dsh}" \
       node --import tsx/esm /app/apps/cli/src/bin.ts \
       plugin --profile web add "dsh-mcp-panel@${DSH_MCP_PANEL_VERSION:-0.6.2}"; then
    echo "dsh: dsh-mcp-panel installed"
  else
    echo "dsh: WARNING: could not install dsh-mcp-panel; run 'dsh plugin --profile web add dsh-mcp-panel' when online" >&2
  fi
fi

# The proxy spawns dsh, relays PUBLIC_PORT -> DSH_PORT, and auto-performs the
# browser-session token exchange so no ?token= is needed. It runs as PID 1 and
# forwards SIGTERM/SIGINT to dsh for a graceful drain.
exec node /app/proxy.mjs
# DeepSeek Harness Docker

Docker image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) built from source, serving the Web UI. Multi-stage build, Renovate-driven
dependency updates, and a GHCR publishing workflow.

The image exposes the Web UI at `http://127.0.0.1:3080`. The harness itself
intentionally refuses to bind `0.0.0.0` and requires a per-launch `?token=`
before serving the UI. A small built-in reverse proxy ([`proxy.mjs`](proxy.mjs))
spawns `dsh web`, captures the token from its stdout, and performs the exchange
transparently — so opening the URL needs **no token**:

```
browser ──> 0.0.0.0:3080 (proxy.mjs, auto-auth) ──> 127.0.0.1:3081 (dsh web)
```

```
browser ──> 0.0.0.0:3080 (proxy.mjs, auto-auth) ──> 127.0.0.1:3081 (dsh web)
```

## Usage

```sh
docker run -d --name deepseek-harness \
  -p 3080:3080 \
  --security-opt seccomp=unconfined \
  -v "$PWD:/workspace" \
  -v dsh-data:/data \
  -e DEEPSEEK_API_KEY=sk-... \
ghcr.io/<owner>/deepseek-harness:latest
```

Then open `http://127.0.0.1:3080`.

### First-time setup in the Web UI

1. **Model**: open **Settings → Models**, confirm the `DEEPSEEK_API_KEY` from the
   environment (or enter another provider's key) and save. To use any
   OpenAI-compatible endpoint (local server, gateway, another vendor), choose
   **Add a custom provider** and fill in a lowercase Provider ID, the base URL
   (e.g. `https://…/v1`), protocol `openai-completions`, an API key, and at
   least one model ID. This is stored in `/data/.dsh/settings.yaml` under
   `llm-pi-ai.providers`; the key is referenced by env var name, not inlined.
2. **Workspace**: click **Choose workspace**, add `/workspace` (the project
   mounted into the container), and select it. Sessions run against that
   directory.

### MCP console (dsh-mcp-panel)

The image pre-installs [dsh-mcp-panel](https://github.com/PerryLink/dsh-mcp-panel)
into the `web` profile — a management console for the official
`@deepseek-ai/dsh-mcp-client`. It adds a **Settings → Plugins → MCP** tab and a
`/mcp` command to view, add, edit, and trial-call MCP servers. Open the tab and
you'll see the MCP server cards immediately.

The bundle is baked into the image at build time and seeded into the `/data`
volume on first start, so fresh containers need no network or manual steps. An
existing volume whose `web` profile predates this image is backfilled with
`dsh plugin --profile web add dsh-mcp-panel` at startup (requires network).

The panel mounts the client for each server you add; the underlying MCP
servers themselves are configured through the tab, so no `cordis.yml` edits are
needed.

## Volumes

| Path          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `/workspace`  | Your project; select this directory as the workspace in the UI |
| `/data`       | `DSH_HOME` — profiles, sessions, credentials, storage          |

## Environment variables

| Variable               | Default            | Notes                                     |
|------------------------|--------------------|-------------------------------------------|
| `DEEPSEEK_API_KEY`     | —                  | API key for the DeepSeek provider         |
| `PUBLIC_PORT`          | `3080`             | Port the proxy listens on (all interfaces)|
| `DSH_PORT`             | `3081`             | Loopback port `dsh web` binds             |
| `DSH_PERMISSION_MODE`  | `workspace-write`  | Session permission preset                 |
| `DSH_TOOLS_MODE`       | `native`           | Tool presentation mode                    |
| `DSH_TELEMETRY_MODE`   | `DISABLED`         | Telemetry is disabled in this image       |
| `DSH_MCP_PANEL_VERSION`| `0.6.2`            | dsh-mcp-panel version baked at build time |

## Security note

The proxy deliberately disables the harness' browser-session token barrier:
anyone who can reach `PUBLIC_PORT` gets a working session (including file
access and command execution in the workspace). Only expose it on a trusted
network or localhost.

## Sandbox (bubblewrap)

The harness runs agent bash commands under the `bwrap` sandbox backend, which
needs to create user namespaces. Docker's **default seccomp profile blocks
that**, so run the container with `--security-opt seccomp=unconfined` (as in the
usage example above). `--privileged` also works but is heavier-handed. The
entrypoint probes `bwrap` at startup and prints a warning with these flags if it
is blocked.

## Building

```sh
docker build -t deepseek-harness .
```

`ARG DSH_VERSION` selects the upstream release tag (Renovate keeps it current):

```sh
docker build --build-arg DSH_VERSION=master -t deepseek-harness .
```

## Renovate

[`renovate.json`](renovate.json) opens nightly PRs for:

- `deepseek-ai/deepseek-harness` (via `github-releases`, tags `dsh-v…`)
- `dsh-mcp-panel` (via `npm`, pinned by the `DSH_MCP_PANEL_VERSION` build arg)
- `pnpm` (pinned to the upstream `packageManager` field)
- the `node` base image (default `dockerfile` manager)

## Publishing

[`.github/workflows/container.yaml`](.github/workflows/container.yaml) builds
and pushes `ghcr.io/<owner>/deepseek-harness:latest` (owner = the GitHub
account/org hosting this repository) on every `main` push and `v*` tag. Add a
`GHCR_TOKEN` secret with `packages:write` scope.

## Caveats

- The project is in developer preview; expect breaking upstream changes.
- The build applies [`patches/mcp-client-onerror.patch`](patches/mcp-client-onerror.patch):
  a lost streamable-HTTP MCP session surfaces via `transport.onerror`, not
  `onclose`, so the client supervisor would otherwise keep a dead generation
  current and 404 every later call. The patch hooks `onerror` to reconnect and
  is removed once the fix lands upstream (`git apply` fails loudly on drift).
- Workspace selection uses the Web UI's directory picker; in a headless
  container this may fall back to the browse variant.
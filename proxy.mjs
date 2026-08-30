#!/usr/bin/env node
/**
 * Reverse proxy + auth-relay for the DeepSeek Harness Web UI.
 *
 * `dsh web` intentionally binds 127.0.0.1 and requires a per-process
 * `?token=` exchange before it serves the index or /api. This proxy
 * (a) spawns dsh itself, (b) captures the printed token URL from its stdout,
 * and (c) transparently performs the token exchange on the first index load,
 * so the browser ends up with the signed cookie automatically — a
 * no-token UX.
 *
 * Architecture:
 *   browser --> 0.0.0.0:PUBLIC_PORT (this proxy) --> 127.0.0.1:DSH_PORT (dsh)
 *
 * Security note: this disables the harness' browser-session barrier. Anyone
 * who can reach PUBLIC_PORT gets a working session (remote code execution).
 * Only run it on a trusted network / localhost.
 */

import { spawn } from 'node:child_process'
import { connect } from 'node:net'
import { createServer, request as httpRequest } from 'node:http'

const PUBLIC_PORT = Number(process.env.PUBLIC_PORT ?? 3080)
const DSH_PORT = Number(process.env.DSH_PORT ?? 3081)
const UPSTREAM_HOST = '127.0.0.1'

// The signed browser cookie minted by the token exchange starts with this
// name; its presence means the browser already holds a session cookie.
const AUTH_COOKIE_RE = /(?:^|;\s*)dsh-auth-[A-Za-z0-9_-]+=/i

let token = null
let tokenWaiters = []

function whenToken(timeoutMs) {
  if (token !== null) return Promise.resolve(token)
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      tokenWaiters = tokenWaiters.filter((w) => w.resolve !== resolve)
      reject(new Error('proxy: dsh did not print a token URL in time'))
    }, timeoutMs)
    tokenWaiters.push({ resolve: (t) => { clearTimeout(timer); resolve(t) } })
  })
}

// ── bootstrap: launch dsh web and capture the token URL from stdout ────────
const TOKEN_PATTERN = /https?:\/\/\S+?\?token=([A-Za-z0-9_-]+)/
const dsh = spawn(
  'node',
  ['--import', 'tsx/esm', '/app/apps/cli/src/bin.ts', 'web', '--no-open', '--port', String(DSH_PORT)],
  { stdio: ['ignore', 'pipe', 'inherit'], env: process.env },
)

let stdoutBuffer = ''
dsh.stdout.setEncoding('utf8')
dsh.stdout.on('data', (chunk) => {
  stdoutBuffer += chunk
  let newline
  while ((newline = stdoutBuffer.indexOf('\n')) !== -1) {
    handleLine(stdoutBuffer.slice(0, newline))
    stdoutBuffer = stdoutBuffer.slice(newline + 1)
  }
})
dsh.stdout.on('end', () => { if (stdoutBuffer.length > 0) handleLine(stdoutBuffer) })

function handleLine(line) {
  console.log(`dsh: ${line}`)
  const match = line.match(TOKEN_PATTERN)
  if (match !== null && token === null) {
    token = match[1]
    console.log(`proxy: token ready; http://127.0.0.1:${PUBLIC_PORT}/ now self-authenticates`)
    for (const waiter of tokenWaiters) waiter.resolve(token)
    tokenWaiters = []
  }
}

dsh.on('exit', (code, signal) => {
  console.error(`proxy: dsh exited (${code ?? signal}); shutting down`)
  process.exit(code ?? 1)
})

// Forward termination to dsh so it can drain gracefully (it is our child, not
// PID 1).
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => dsh.kill(signal))
}

// ── the proxy ───────────────────────────────────────────────────────────────
function tokenExchange(req, res) {
  const upstream = httpRequest(
    {
      hostname: UPSTREAM_HOST,
      port: DSH_PORT,
      path: `/?token=${encodeURIComponent(token)}`,
      method: 'GET',
      headers: { host: req.headers.host, connection: 'close' },
    },
    (up) => {
      res.writeHead(up.statusCode ?? 500, up.headers)
      up.pipe(res)
    },
  )
  upstream.on('error', (error) => {
    if (!res.headersSent) {
      res.writeHead(502)
      res.end(`proxy: token exchange failed: ${error.message}`)
    } else {
      res.destroy(error)
    }
  })
  upstream.end()
}

/** Relay a request, buffering the response so the caller can inspect status. */
function bufferRelay(req) {
  return new Promise((resolve, reject) => {
    const upstream = httpRequest(
      {
        hostname: UPSTREAM_HOST,
        port: DSH_PORT,
        path: req.url,
        method: req.method,
        headers: { ...req.headers, connection: 'close' },
      },
      (up) => {
        const chunks = []
        up.on('data', (chunk) => chunks.push(chunk))
        up.on('end', () =>
          resolve({ status: up.statusCode ?? 500, headers: up.headers, body: Buffer.concat(chunks) }))
      },
    )
    upstream.on('error', reject)
    req.pipe(upstream)
  })
}

/** Relay a request, streaming the response. */
function streamRelay(req, res) {
  const upstream = httpRequest(
    {
      hostname: UPSTREAM_HOST,
      port: DSH_PORT,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, connection: 'close' },
    },
    (up) => {
      res.writeHead(up.statusCode ?? 500, up.headers)
      up.pipe(res)
    },
  )
  upstream.on('error', (error) => {
    if (!res.headersSent) {
      res.writeHead(502)
      res.end(`proxy: upstream error: ${error.message}`)
    } else {
      res.destroy(error)
    }
  })
  req.pipe(upstream)
}

function handleIndex(req, res) {
  const bootstrap = () =>
    whenToken(120_000)
      .then(() => tokenExchange(req, res))
      .catch((error) => {
        res.writeHead(503)
        res.end(error.message)
      })

  // No session cookie yet: mint one via the token exchange (dsh answers 303 +
  // Set-Cookie + Location: /). The browser follows to "/" with the cookie.
  if (!AUTH_COOKIE_RE.test(req.headers.cookie ?? '')) {
    bootstrap()
    return
  }

  // Cookie present: relay so dsh serves the index. If the cookie is stale/expired
  // (401), renew it through the token exchange instead of showing the 401 page.
  bufferRelay(req)
    .then(({ status, headers, body }) => {
      if (status === 401) {
        bootstrap()
        return
      }
      res.writeHead(status, headers)
      res.end(body)
    })
    .catch((error) => {
      res.writeHead(502)
      res.end(`proxy: upstream error: ${error.message}`)
    })
}

const server = createServer((req, res) => {
  let pathname
  try {
    pathname = new URL(req.url, 'http://dsh.invalid').pathname
  } catch {
    res.writeHead(400)
    res.end('bad request')
    return
  }

  if (req.method === 'GET' && pathname === '/') {
    handleIndex(req, res)
    return
  }

  streamRelay(req, res)
})

// Preserve any raw-socket upgrade (WebSocket-style) transports to upstream.
server.on('upgrade', (req, socket, head) => {
  const upstream = connect(DSH_PORT, UPSTREAM_HOST, () => {
    const headLines = [
      `${req.method} ${req.url} HTTP/1.1`,
      ...Object.entries(req.headers).map(([name, value]) => `${name}: ${value}`),
      '',
      '',
    ]
    upstream.write(headLines.join('\r\n'))
    if (head !== null && head.length > 0) upstream.write(head)
    upstream.pipe(socket).pipe(upstream)
  })
  upstream.on('error', () => socket.destroy())
  socket.on('error', () => upstream.destroy())
})

server.listen(PUBLIC_PORT, '0.0.0.0', () => {
  console.log(`proxy: listening on 0.0.0.0:${PUBLIC_PORT} -> 127.0.0.1:${DSH_PORT}`)
})
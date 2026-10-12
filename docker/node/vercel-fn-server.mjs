// ---------------------------------------------------------------------------
// Local stand-in for the Vercel Node.js runtime.
//
// Serves every file under ./api as a function, the way Vercel does:
//   api/process.ts                    ->  /api/process
//   api/ingest/[slug].js              ->  /api/ingest/:slug   (req.query.slug)
//
// Handlers get the Vercel helpers they rely on: req.query, req.cookies,
// req.body (parsed lazily, so handlers that read the raw stream themselves
// still can), res.status(), res.json(), res.send(), res.redirect().
//
// Not emulated: maxDuration, body size limits, vercel.json rewrites.
// Run with tsx so TypeScript functions load without a build step.
// ---------------------------------------------------------------------------

import http from 'node:http'
import path from 'node:path'
import { readdirSync } from 'node:fs'
import { Readable } from 'node:stream'
import { pathToFileURL } from 'node:url'

const API_DIR = path.resolve(process.env.FUNCTIONS_DIR ?? 'api')
const PORT    = Number(process.env.PORT) || 3000

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

function listFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name)
    return entry.isDirectory() ? listFiles(full) : [full]
  })
}

const routes = listFiles(API_DIR)
  .filter(file => /\.(js|mjs|cjs|ts|mts)$/.test(file) && !file.endsWith('.d.ts'))
  .map(file => {
    const segments = ['api', ...path.relative(API_DIR, file).replace(/\.[^.]+$/, '').split(path.sep)]
    if (segments.at(-1) === 'index') segments.pop()
    return { file, segments, pattern: '/' + segments.join('/'), handler: null }
  })
  // Static routes win over dynamic ones
  .sort((a, b) => a.pattern.split('[').length - b.pattern.split('[').length)

for (const route of routes) {
  try {
    const mod = await import(pathToFileURL(route.file).href)
    // ESM default export, or CommonJS module.exports
    route.handler = [mod.default, mod.default?.default].find(h => typeof h === 'function') ?? null
    if (!route.handler) console.error(`[server] ${route.pattern}: no default export function`)
  } catch (err) {
    console.error(`[server] ${route.pattern}: failed to load`, err)
  }
}

function matchRoute(pathname) {
  const parts = pathname.split('/').filter(Boolean)
  for (const route of routes) {
    if (route.segments.length !== parts.length) continue
    const params = {}
    const ok = route.segments.every((segment, i) => {
      const param = segment.match(/^\[(.+)\]$/)
      if (param) { params[param[1]] = decodeURIComponent(parts[i]); return true }
      return segment === parts[i]
    })
    if (ok) return { route, params }
  }
  return null
}

// ---------------------------------------------------------------------------
// Request / response helpers
// ---------------------------------------------------------------------------

function parseBody(raw, content_type) {
  if (raw.length === 0) return undefined
  const type = content_type.split(';')[0].trim().toLowerCase()
  if (type === 'application/json') return JSON.parse(raw.toString('utf8'))
  if (type === 'application/x-www-form-urlencoded') return Object.fromEntries(new URLSearchParams(raw.toString('utf8')))
  if (type === 'application/octet-stream') return raw
  return raw.toString('utf8')
}

async function buildRequest(incoming, url, params) {
  const chunks = []
  for await (const chunk of incoming) chunks.push(chunk)
  const raw = Buffer.concat(chunks)

  // Replayable stream: the body stays readable through req.on('data')
  const req = Readable.from(raw.length ? [raw] : [], { objectMode: false })
  Object.assign(req, {
    method:      incoming.method,
    url:         incoming.url,
    headers:     incoming.headers,
    rawHeaders:  incoming.rawHeaders,
    httpVersion: incoming.httpVersion,
    socket:      incoming.socket,
    query:       { ...Object.fromEntries(url.searchParams), ...params },
    cookies:     Object.fromEntries(
      (incoming.headers.cookie ?? '').split(';').map(c => c.trim().split('=')).filter(([k]) => k)
        .map(([k, ...v]) => [k, decodeURIComponent(v.join('='))])
    ),
  })

  let body, parsed = false
  Object.defineProperty(req, 'body', {
    get() {
      if (!parsed) { body = parseBody(raw, incoming.headers['content-type'] ?? ''); parsed = true }
      return body
    },
    set(value) { body = value; parsed = true },
  })

  return req
}

function decorateResponse(res) {
  res.status = code => { res.statusCode = code; return res }
  res.json = data => {
    if (!res.hasHeader('content-type')) res.setHeader('content-type', 'application/json; charset=utf-8')
    res.end(JSON.stringify(data))
    return res
  }
  res.send = data => {
    if (data !== null && typeof data === 'object' && !Buffer.isBuffer(data)) return res.json(data)
    res.end(data)
    return res
  }
  res.redirect = (status_or_url, maybe_url) => {
    const [status, location] = maybe_url ? [status_or_url, maybe_url] : [307, status_or_url]
    res.writeHead(status, { location }).end()
    return res
  }
  return res
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = http.createServer(async (incoming, outgoing) => {
  const started = Date.now()
  const url     = new URL(incoming.url, 'http://localhost')
  const res     = decorateResponse(outgoing)

  res.on('finish', () => {
    console.log(`[server] ${incoming.method} ${url.pathname} ${res.statusCode} ${Date.now() - started}ms`)
  })

  // Lists the functions; also used as the container healthcheck
  if (url.pathname === '/') {
    return res.status(200).json({ functions: routes.map(r => ({ path: r.pattern, loaded: Boolean(r.handler) })) })
  }

  const match = matchRoute(url.pathname)
  if (!match) return res.status(404).json({ error: 'Not found' })
  if (!match.route.handler) return res.status(500).json({ error: 'Function failed to load, see the container log' })

  try {
    const req = await buildRequest(incoming, url, match.params)
    await match.route.handler(req, res)
  } catch (err) {
    console.error(`[server] ${url.pathname} threw:`, err)
    if (!res.headersSent) res.status(500).json({ error: 'A server error has occurred' })
    else res.end()
  }
})

// Background work (waitUntil promises) must not take the server down
process.on('unhandledRejection', err => console.error('[server] unhandled rejection:', err))
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0))

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[server] listening on :${PORT}`)
  for (const route of routes) console.log(`[server]   ${route.pattern}${route.handler ? '' : '  (NOT LOADED)'}`)
})

import http from 'node:http'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'

const PORT = Number(process.env.PORT || 8000)
const TAVILY_KEY = process.env.TAVILY_API_KEY || ''
const EXA_KEY = process.env.EXA_API_KEY || ''
const PROXY_KEY = process.env.PROXY_API_KEY || ''
const DEFAULT_PROVIDER = process.env.SEARCH_PROVIDER || 'tavily'
const EXA_LIMIT = Number(process.env.EXA_MONTHLY_LIMIT || 10)
const USAGE_FILE = process.env.USAGE_FILE || '/data/usage.json'
const RATE_WINDOW_MS = 60000
const RATE_MAX = Number(process.env.RATE_LIMIT_PER_MIN || 60)

const hits = new Map()
let tavilyCache = { at: 0, data: null }

function json(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

async function readBody(req) {
  const chunks = []
  for await (const c of req) chunks.push(c)
  const raw = Buffer.concat(chunks).toString('utf8')
  if (!raw) return {}
  try { return JSON.parse(raw) } catch { return {} }
}

function authorized(req) {
  const h = req.headers['authorization'] || ''
  return PROXY_KEY === '' || h === `Bearer ${PROXY_KEY}`
}

function rateLimited(ip) {
  if (hits.size > 10000) hits.clear()
  const now = Date.now()
  const win = hits.get(ip)
  if (!win || now - win.start > RATE_WINDOW_MS) {
    hits.set(ip, { start: now, count: 1 })
    return false
  }
  win.count += 1
  return win.count > RATE_MAX
}

async function loadUsage() {
  try {
    return JSON.parse(await readFile(USAGE_FILE, 'utf8'))
  } catch {
    return { exa_spent_usd: 0, exa_queries: 0, month: new Date().toISOString().slice(0, 7) }
  }
}

async function saveUsage(u) {
  try {
    await mkdir(path.dirname(USAGE_FILE), { recursive: true })
    await writeFile(USAGE_FILE, JSON.stringify(u), 'utf8')
  } catch {}
}

async function tavilyUsage() {
  if (tavilyCache.data && Date.now() - tavilyCache.at < 600000) return tavilyCache.data
  const res = await fetch('https://api.tavily.com/usage', {
    headers: { authorization: `Bearer ${TAVILY_KEY}` },
  })
  if (!res.ok) throw new Error(`tavily usage ${res.status}`)
  const data = await res.json()
  tavilyCache = { at: Date.now(), data }
  return data
}

function truncate(s, n) {
  if (!s) return ''
  return s.length > n ? s.slice(0, n) + '...' : s
}

async function searchTavily(query, num) {
  const res = await fetch('https://api.tavily.com/search', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TAVILY_KEY}` },
    body: JSON.stringify({ query, max_results: num || 5, search_depth: 'basic' }),
  })
  if (!res.ok) throw new Error(`tavily search ${res.status}`)
  const data = await res.json()
  const results = (data.results || []).map(r => ({
    title: r.title || '', url: r.url || '', snippet: truncate(r.content, 300),
  }))
  return { provider: 'tavily', query, results }
}

async function searchExa(query, num) {
  const res = await fetch('https://api.exa.ai/search', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': EXA_KEY },
    body: JSON.stringify({ query, numResults: num || 5, contents: { text: { maxCharacters: 300 } } }),
  })
  if (!res.ok) throw new Error(`exa search ${res.status}`)
  const data = await res.json()
  const results = (data.results || []).map(r => ({
    title: r.title || '', url: r.url || '',
    snippet: truncate(r.text || (r.highlights && r.highlights[0]) || '', 300),
  }))
  const cost = Number((data.costDollars && data.costDollars.total) || 0)
  return { provider: 'exa', query, results, cost }
}

const server = http.createServer(async (req, res) => {
  const ip = (req.socket.remoteAddress || '').replace('::ffff:', '')
  if (rateLimited(ip)) return json(res, 429, { error: 'rate limited' })
  if (!authorized(req)) return json(res, 401, { error: 'unauthorized' })

  const url = new URL(req.url, `http://${req.headers.host}`)

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { ok: true })
  }

  if (req.method === 'GET' && url.pathname === '/usage') {
    try {
      const u = await loadUsage()
      const month = new Date().toISOString().slice(0, 7)
      if (u.month !== month) { u.month = month; u.exa_spent_usd = 0; u.exa_queries = 0 }
      let tavily = { available: false }
      if (TAVILY_KEY) {
        try {
          const t = await tavilyUsage()
          const limit = (t.key && t.key.limit) ?? (t.account && t.account.plan_limit) ?? null
          const used = (t.key && t.key.usage) ?? (t.account && t.account.plan_usage) ?? 0
          tavily = {
            available: true, used, limit,
            remaining: limit == null ? null : Math.max(0, limit - used),
            plan: t.account ? t.account.current_plan : null,
          }
        } catch (e) { tavily = { available: false, error: String(e.message) } }
      }
      return json(res, 200, {
        tavily,
        exa: {
          available: !!EXA_KEY,
          spent_usd: u.exa_spent_usd,
          limit_usd: EXA_LIMIT,
          remaining_usd: Math.max(0, EXA_LIMIT - u.exa_spent_usd),
          queries: u.exa_queries,
        },
      })
    } catch (e) {
      return json(res, 500, { error: String(e.message) })
    }
  }

  if (req.method === 'POST' && url.pathname === '/search') {
    const body = await readBody(req)
    const query = body.query
    if (!query) return json(res, 400, { error: 'query required' })
    const provider = (body.provider || url.searchParams.get('provider') || DEFAULT_PROVIDER).toLowerCase()
    const num = body.numResults || Number(url.searchParams.get('num') || 5)
    try {
      if (provider === 'exa') {
        const out = await searchExa(query, num)
        if (EXA_KEY) {
          const u = await loadUsage()
          u.exa_spent_usd = (u.exa_spent_usd || 0) + (out.cost || 0)
          u.exa_queries = (u.exa_queries || 0) + 1
          u.month = new Date().toISOString().slice(0, 7)
          await saveUsage(u)
        }
        return json(res, 200, out)
      }
      return json(res, 200, await searchTavily(query, num))
    } catch (e) {
      return json(res, 502, { error: String(e.message) })
    }
  }

  return json(res, 404, { error: 'not found' })
})

server.listen(PORT)

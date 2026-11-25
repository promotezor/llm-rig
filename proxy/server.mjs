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
const DAILY_CAP = Number(process.env.SEARCH_DAILY_CAP || 0)

const hits = new Map()
let tavilyCache = { at: 0, data: null }
let searchEnabled = true

function today() { return new Date().toISOString().slice(0, 10) }

function json(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

function html(res, code, body) {
  res.writeHead(code, { 'content-type': 'text/html; charset=utf-8' })
  res.end(body)
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
    const u = JSON.parse(await readFile(USAGE_FILE, 'utf8'))
    if (u.day !== today()) { u.day = today(); u.queries_today = 0 }
    if (typeof u.search_enabled !== 'boolean') u.search_enabled = true
    return u
  } catch {
    return {
      exa_spent_usd: 0, exa_queries: 0, month: today().slice(0, 7),
      day: today(), queries_today: 0, search_enabled: true,
    }
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

function page() {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>llm-rig</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 460px; margin: 40px auto; padding: 0 16px; background: #111; color: #eee; }
  input, button { font-size: 16px; padding: 9px 12px; border-radius: 6px; border: 1px solid #444; }
  input { background: #222; color: #eee; width: 100%; box-sizing: border-box; }
  button { background: #333; color: #eee; cursor: pointer; }
  button:hover { background: #444; }
  .row { margin: 16px 0; }
  .on { color: #6f6; font-weight: bold; }
  .off { color: #f66; font-weight: bold; }
  pre { background: #1a1a1a; padding: 12px; border-radius: 6px; font-size: 13px; line-height: 1.5; }
</style>
<h1>llm-rig</h1>
<div class="row">
  <input id="key" type="password" placeholder="PROXY_API_KEY">
</div>
<div class="row">
  поиск: <span id="status">-</span>
  <button id="toggle">переключить</button>
</div>
<pre id="usage">загрузка...</pre>
<script>
const el = (id) => document.getElementById(id)
const auth = () => ({ 'Authorization': 'Bearer ' + el('key').value })
async function refresh() {
  try {
    const u = await (await fetch('/usage', { headers: auth() })).json()
    const t = u.tavily, e = u.exa, s = u.search
    el('status').textContent = s.enabled ? 'ВКЛ' : 'ВЫКЛ'
    el('status').className = s.enabled ? 'on' : 'off'
    el('usage').innerHTML = [
      'Tavily остаток: ' + (t.available ? (t.remaining == null ? 'без лимита' : t.remaining) : 'нет ключа'),
      'Exa остаток: $' + (e.available ? e.remaining_usd : 'нет ключа'),
      'запросов сегодня: ' + s.queries_today + (s.daily_cap ? ' / ' + s.daily_cap : ''),
    ].join('<br>')
  } catch (err) {
    el('usage').textContent = 'ошибка: проверь ключ'
  }
}
el('toggle').onclick = async () => {
  await fetch('/toggle', { method: 'POST', headers: { 'content-type': 'application/json', ...auth() }, body: '{}' })
  refresh()
}
el('key').onchange = refresh
refresh()
</script>
`
}

const server = http.createServer(async (req, res) => {
  const ip = (req.socket.remoteAddress || '').replace('::ffff:', '')
  if (rateLimited(ip)) return json(res, 429, { error: 'rate limited' })

  const url = new URL(req.url, `http://${req.headers.host}`)

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    return html(res, 200, page())
  }

  if (!authorized(req)) return json(res, 401, { error: 'unauthorized' })

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { ok: true, search_enabled: searchEnabled })
  }

  if (req.method === 'POST' && url.pathname === '/toggle') {
    const body = await readBody(req)
    const u = await loadUsage()
    u.search_enabled = typeof body.search === 'boolean' ? body.search : !u.search_enabled
    searchEnabled = u.search_enabled
    await saveUsage(u)
    return json(res, 200, { search_enabled: u.search_enabled })
  }

  if (req.method === 'GET' && url.pathname === '/usage') {
    try {
      const u = await loadUsage()
      searchEnabled = u.search_enabled
      const month = today().slice(0, 7)
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
        search: { enabled: u.search_enabled, queries_today: u.queries_today, daily_cap: DAILY_CAP },
      })
    } catch (e) {
      return json(res, 500, { error: String(e.message) })
    }
  }

  if (req.method === 'POST' && url.pathname === '/search') {
    const body = await readBody(req)
    const query = body.query
    if (!query) return json(res, 400, { error: 'query required' })
    const u = await loadUsage()
    if (!u.search_enabled) return json(res, 403, { error: 'search disabled' })
    if (DAILY_CAP > 0 && u.queries_today >= DAILY_CAP) return json(res, 429, { error: 'daily search limit reached' })
    const provider = (body.provider || url.searchParams.get('provider') || DEFAULT_PROVIDER).toLowerCase()
    const num = body.numResults || Number(url.searchParams.get('num') || 5)
    try {
      if (provider === 'exa') {
        const out = await searchExa(query, num)
        if (EXA_KEY) {
          u.exa_spent_usd = (u.exa_spent_usd || 0) + (out.cost || 0)
          u.exa_queries = (u.exa_queries || 0) + 1
          u.month = today().slice(0, 7)
        }
        u.queries_today = (u.queries_today || 0) + 1
        await saveUsage(u)
        return json(res, 200, out)
      }
      const out = await searchTavily(query, num)
      u.queries_today = (u.queries_today || 0) + 1
      await saveUsage(u)
      return json(res, 200, out)
    } catch (e) {
      return json(res, 502, { error: String(e.message) })
    }
  }

  return json(res, 404, { error: 'not found' })
})

server.listen(PORT)

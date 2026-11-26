import http from 'node:http'
import { readFile } from 'node:fs/promises'

const PORT = Number(process.env.STATUS_PORT || 8080)
const STATUS_FILE = process.env.STATUS_FILE || '/dev/shm/llm-rig.status.json'
const LOG_FILE = process.env.LOG_FILE || '/dev/shm/llm-rig.log'

let shuttingDown = false

async function readStatus() {
  try {
    return JSON.parse(await readFile(STATUS_FILE, 'utf8'))
  } catch {
    return { stage: 'starting', note: 'status file not written yet' }
  }
}

async function logTail(lines = 30) {
  try {
    const text = await readFile(LOG_FILE, 'utf8')
    return text.trimEnd().split('\n').slice(-lines).join('\n')
  } catch {
    return 'no log yet'
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)
  const status = await readStatus()

  if (url.pathname === '/status' || url.pathname === '/status.json') {
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(JSON.stringify(status, null, 2))
  }

  if (url.pathname === '/' || url.pathname === '/status.html') {
    const tail = await logTail()
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
    return res.end(`<!doctype html><meta charset="utf-8">
<meta http-equiv="refresh" content="10">
<title>llm-rig status</title>
<style>body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:24px;max-width:900px}
pre{background:#1a1a1a;padding:12px;border-radius:6px;overflow:auto;font-size:13px}</style>
<h1>llm-rig</h1>
<p>Это страница состояния. Чат появится тут же, когда модель загрузится.</p>
<pre>${JSON.stringify(status, null, 2)}</pre>
<h2>log</h2>
<pre>${tail.replace(/[<>&]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]))}</pre>`)
  }

  res.writeHead(404, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ error: 'not found', hint: 'try /status or /' }))
})

async function watchForLaunch() {
  setInterval(async () => {
    const s = await readStatus()
    if (s.stage === 'launching' && !shuttingDown) {
      shuttingDown = true
      console.log('status server: handing the port over to llama-server')
      server.close(() => process.exit(0))
      setTimeout(() => process.exit(0), 2000)
    }
  }, 2000)
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`status server listening on 0.0.0.0:${PORT}`)
  watchForLaunch()
})

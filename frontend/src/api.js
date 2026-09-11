// Same-origin relative paths: works locally (Vite proxies /api to :8000 in
// dev — see vite.config.js) and inside Databricks Apps (backend/app.py
// serves this built frontend AND the /api routes from the same https
// origin, no separate host/port to hardcode).
const API_BASE = ''

async function json(res) {
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`)
  return res.json()
}

export const api = {
  predictQoe: (payload) =>
    fetch(`${API_BASE}/api/predict/qoe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then(json),

  listSites: () => fetch(`${API_BASE}/api/sites`).then(json),

  siteHistory: (siteId) =>
    fetch(`${API_BASE}/api/sites/${encodeURIComponent(siteId)}/history`).then(json),

  predictForecast: (payload) =>
    fetch(`${API_BASE}/api/predict/forecast`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then(json),
}

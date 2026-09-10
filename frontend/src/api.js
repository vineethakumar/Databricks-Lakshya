// Uses whatever host the page itself was loaded from (localhost when
// developing on the same machine, the VM's external IP when accessed
// remotely) so this doesn't need to change based on where it's viewed from.
const API_BASE = `http://${window.location.hostname}:8000`

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

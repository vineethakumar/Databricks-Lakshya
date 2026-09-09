import { useEffect, useState } from 'react'
import { api } from '../api.js'
import MetricCard from './MetricCard.jsx'
import { PhoneIcon, TrendDownIcon, AlertIcon } from './icons.jsx'
import { riskStyle } from '../theme.js'

// Matches src/features.py FEATURE_COLUMNS minus the computed hour_sin/hour_cos.
const NUMERIC_COLUMNS = [
  'total_calls', 'dropped_calls', 'failed_calls', 'blocked_calls', 'success_rate',
  'latency_ms', 'jitter_ms', 'packet_drop_rate', 'call_drop_rate',
  'rrc_setup_success_rate', 'throughput_mbps',
  'alarm_count', 'critical_alarm_count', 'event_count',
]

const COLUMN_LABELS = {
  total_calls: 'Total calls', dropped_calls: 'Dropped', failed_calls: 'Failed',
  blocked_calls: 'Blocked', success_rate: 'Success rate', latency_ms: 'Latency (ms)',
  jitter_ms: 'Jitter (ms)', packet_drop_rate: 'Pkt drop', call_drop_rate: 'Call drop',
  rrc_setup_success_rate: 'RRC success', throughput_mbps: 'Throughput (Mbps)',
  alarm_count: 'Alarms', critical_alarm_count: 'Critical alarms', event_count: 'Events',
}

function formatHour(ts) {
  const d = new Date(ts.replace(' ', 'T'))
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

export default function LstmForecast() {
  const [sites, setSites] = useState([])
  const [siteId, setSiteId] = useState('')
  const [rows, setRows] = useState([])
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    api.listSites().then((s) => {
      setSites(s)
      if (s.length) setSiteId(s[0])
    }).catch((err) => setError(err.message))
  }, [])

  useEffect(() => {
    if (!siteId) return
    setResult(null)
    api.siteHistory(siteId).then(setRows).catch((err) => setError(err.message))
  }, [siteId])

  function setCell(rowIndex, key, value) {
    setRows((prev) => prev.map((r, i) => (i === rowIndex ? { ...r, [key]: Number(value) } : r)))
  }

  async function handlePredict() {
    setLoading(true)
    setError(null)
    try {
      setResult(await api.predictForecast({ site_id: siteId, history: rows }))
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const risk = result ? riskStyle(result.risk_level) : null

  return (
    <div>
      <div className="card toolbar-card">
        <div>
          <span className="field-label">Site</span>
          <select className="site-select" value={siteId} onChange={(e) => setSiteId(e.target.value)}>
            {sites.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
        <button className="btn-primary" onClick={handlePredict} disabled={loading || !rows.length}>
          {loading ? 'Predicting…' : 'Predict call-event forecast'}
        </button>
      </div>

      <div className="metric-row">
        <MetricCard
          icon={<PhoneIcon />}
          label="Predicted call volume"
          value={result ? result.predicted_call_volume.toFixed(0) : '—'}
          hint="calls in the next forecast window"
        />
        <MetricCard
          icon={<TrendDownIcon />}
          label="Predicted drop rate"
          value={result ? `${(result.predicted_drop_rate * 100).toFixed(2)}%` : '—'}
        />
        <MetricCard
          icon={<AlertIcon />}
          label="Predicted failure probability"
          value={result ? `${(result.predicted_failure_prob * 100).toFixed(2)}%` : '—'}
          badge={result?.risk_level}
          badgeStyle={risk}
        />
      </div>

      {error && <p className="error">{error}</p>}

      <div className="card">
        <h2>Last {rows.length || 24} hours — {siteId}</h2>
        <p className="card-subtitle">Edit any cell to run a what-if scenario, then predict above.</p>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th className="ts-col">Hour</th>
                {NUMERIC_COLUMNS.map((c) => <th key={c}>{COLUMN_LABELS[c]}</th>)}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, i) => (
                <tr key={row.hour_ts}>
                  <td className="ts-cell">{formatHour(row.hour_ts)}</td>
                  {NUMERIC_COLUMNS.map((c) => (
                    <td key={c}>
                      <input
                        type="number"
                        step="any"
                        value={row[c]}
                        onChange={(e) => setCell(i, c, e.target.value)}
                      />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}

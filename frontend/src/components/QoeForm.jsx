import { useState } from 'react'
import { api } from '../api.js'
import Gauge from './Gauge.jsx'
import { qoeBandStyle, QOE_INTERPRETATION } from '../theme.js'

const DEFAULTS = {
  latency_ms: 30,
  jitter_ms: 3,
  packet_drop_rate: 0.01,
  call_drop_rate: 0.01,
  rrc_setup_success_rate: 0.98,
  throughput_mbps: 90,
  segment: 'HIGH_VALUE',
}

const FIELDS = [
  { key: 'latency_ms', label: 'Latency', unit: 'ms', step: 1 },
  { key: 'jitter_ms', label: 'Jitter', unit: 'ms', step: 0.1 },
  { key: 'packet_drop_rate', label: 'Packet drop rate', unit: '0–1', step: 0.0001 },
  { key: 'call_drop_rate', label: 'Call drop rate', unit: '0–1', step: 0.0001 },
  { key: 'rrc_setup_success_rate', label: 'RRC setup success rate', unit: '0–1', step: 0.0001 },
  { key: 'throughput_mbps', label: 'Throughput', unit: 'Mbps', step: 1 },
]

export default function QoeForm() {
  const [values, setValues] = useState(DEFAULTS)
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)

  function setField(key, value) {
    setValues((v) => ({ ...v, [key]: value }))
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setLoading(true)
    setError(null)
    try {
      const payload = { ...values }
      for (const f of FIELDS) payload[f.key] = Number(payload[f.key])
      setResult(await api.predictQoe(payload))
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const style = result ? qoeBandStyle(result.band) : null

  return (
    <div className="split">
      <div className="card">
        <h2>KPI reading</h2>
        <p className="card-subtitle">Enter the current network conditions for a site.</p>
        <form onSubmit={handleSubmit} className="form-grid">
          {FIELDS.map((f) => (
            <label key={f.key}>
              <span className="field-label">
                {f.label} <span className="field-unit">{f.unit}</span>
              </span>
              <input
                type="number"
                step={f.step}
                value={values[f.key]}
                onChange={(e) => setField(f.key, e.target.value)}
              />
            </label>
          ))}
          <label>
            <span className="field-label">Subscriber segment</span>
            <select value={values.segment} onChange={(e) => setField('segment', e.target.value)}>
              <option value="HIGH_VALUE">High value</option>
              <option value="MEDIUM_VALUE">Medium value</option>
              <option value="LOW_VALUE">Low value</option>
            </select>
          </label>
          <button type="submit" className="btn-primary" disabled={loading}>
            {loading ? 'Predicting…' : 'Predict QoE score'}
          </button>
        </form>
        {error && <p className="error">{error}</p>}
      </div>

      <div className="card result-card">
        <h2>Predicted quality of experience</h2>
        {!result ? (
          <div className="empty-state">
            <Gauge value={0} color="#d8dbe2" />
            <p>Run a prediction to see the score here.</p>
          </div>
        ) : (
          <>
            <Gauge value={result.score} color={style.ring} />
            <span className="badge badge-lg" style={{ color: style.fg, background: style.bg }}>
              {result.band}
            </span>
            <p className="interpretation">{QOE_INTERPRETATION[result.band]}</p>
          </>
        )}
      </div>
    </div>
  )
}

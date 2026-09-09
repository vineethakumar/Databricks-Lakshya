import { useState } from 'react'
import Header from './components/Header.jsx'
import QoeForm from './components/QoeForm.jsx'
import LstmForecast from './components/LstmForecast.jsx'

const TABS = [
  { id: 'qoe', label: 'QoE Score', description: 'Predict customer experience from a live KPI reading' },
  { id: 'lstm', label: 'Call-Event Forecast', description: 'Forecast call volume, drop rate & failure risk per site' },
]

export default function App() {
  const [tab, setTab] = useState('qoe')
  const active = TABS.find((t) => t.id === tab)

  return (
    <div className="shell">
      <Header />

      <main className="content">
        <nav className="segmented">
          {TABS.map((t) => (
            <button
              key={t.id}
              className={t.id === tab ? 'active' : ''}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </nav>
        <p className="tab-description">{active.description}</p>

        {tab === 'qoe' ? <QoeForm /> : <LstmForecast />}
      </main>

      <footer className="app-footer">
        Powered by a gradient-boosted QoE regressor and an LSTM call-event forecaster — trained on live network telemetry.
      </footer>
    </div>
  )
}

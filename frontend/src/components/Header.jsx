export default function Header() {
  return (
    <header className="app-header">
      <div className="brand">
        <div className="brand-mark">NI</div>
        <div>
          <div className="brand-name">Network Intelligence Platform</div>
          <div className="brand-tagline">Call Failure &amp; Customer Experience Prediction</div>
        </div>
      </div>
      <div className="env-badge">
        <span className="env-dot" />
        Live model inference
      </div>
    </header>
  )
}

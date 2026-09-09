export default function MetricCard({ icon, label, value, badge, badgeStyle, hint }) {
  return (
    <div className="metric-card">
      <div className="metric-card-top">
        {icon && <span className="metric-card-icon">{icon}</span>}
        <span className="metric-card-label">{label}</span>
      </div>
      <span className="metric-card-value">{value}</span>
      <div className="metric-card-bottom">
        {badge && (
          <span className="badge" style={{ color: badgeStyle?.fg, background: badgeStyle?.bg }}>
            {badge}
          </span>
        )}
        {hint && <span className="metric-card-hint">{hint}</span>}
      </div>
    </div>
  )
}

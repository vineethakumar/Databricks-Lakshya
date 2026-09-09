// Shared color mapping so the QoE band and LSTM risk-level badges/gauges
// read as one consistent visual language across both tabs.
const SCALE = {
  best: { fg: '#0f7a4d', bg: '#e7f7ef', ring: '#16a34a' },
  good: { fg: '#1d4ed8', bg: '#eaf1ff', ring: '#3b82f6' },
  fair: { fg: '#92660a', bg: '#fef6e0', ring: '#eab308' },
  poor: { fg: '#b45309', bg: '#fef1e2', ring: '#f97316' },
  bad: { fg: '#b91c1c', bg: '#fdeaea', ring: '#ef4444' },
}

export function qoeBandStyle(band) {
  switch (band) {
    case 'EXCELLENT': return SCALE.best
    case 'GOOD': return SCALE.good
    case 'FAIR': return SCALE.fair
    case 'POOR': return SCALE.poor
    default: return SCALE.bad
  }
}

export function riskStyle(level) {
  switch (level) {
    case 'LOW': return SCALE.best
    case 'MODERATE': return SCALE.fair
    case 'HIGH': return SCALE.poor
    default: return SCALE.bad
  }
}

export const QOE_INTERPRETATION = {
  EXCELLENT: 'Customers on this connection are very likely reporting an excellent experience. No action needed.',
  GOOD: 'Customers are experiencing solid quality with only minor room for improvement.',
  FAIR: 'Quality is acceptable but noticeable — some customers may perceive degraded service.',
  POOR: 'Quality is poor. Proactive outreach or a maintenance window is recommended.',
  CRITICAL: 'Quality is critical. Immediate intervention is recommended to prevent customer churn.',
}

"""Generates the same synthetic dataset as scripts/demo_local_no_db.py, but
writes it to CSV under data/mock/ instead of only holding it in memory —
so you can open the files and see exactly what data feeds the KPI/QoE/
triage logic, and how each KPI column drives the scores in
db/03_packages.sql (PKG_QOE_SCORING, PKG_TRIAGE).

Writes:
    data/mock/site_hourly_features.csv   one row per site per hour — the raw
                                          KPI + call-volume columns behind
                                          VW_SITE_HOURLY_FEATURES
                                          (db/02_views.sql); this is the
                                          LSTM's training/inference input.
    data/mock/qoe_training_data.csv      KPI reading -> NPS/CSAT per segment,
                                          behind VW_QOE_TRAINING_DATA
                                          (db/02_views.sql); this is the QoE
                                          regressor's training input.
    data/mock/site_meta.csv              per-site subscriber-value mix
                                          (high-value count, total ARPU),
                                          behind VW_SITE_SUBSCRIBER_VALUE
                                          (db/02_views.sql); used to weight
                                          customer_impact_score.

Usage:
    python scripts/generate_mock_csv.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.mock_data import generate_all

OUT_DIR = Path(__file__).resolve().parent.parent / "data" / "mock"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    raw_df, qoe_df, site_meta_df = generate_all()

    raw_path = OUT_DIR / "site_hourly_features.csv"
    qoe_path = OUT_DIR / "qoe_training_data.csv"
    meta_path = OUT_DIR / "site_meta.csv"

    raw_df.to_csv(raw_path, index=False)
    qoe_df.to_csv(qoe_path, index=False)
    site_meta_df.to_csv(meta_path, index=False)

    print(f"wrote {len(raw_df)} rows -> {raw_path}")
    print("  columns: site_id, hour_ts, total_calls/dropped_calls/failed_calls/blocked_calls/"
          "success_rate (call volume), latency_ms/jitter_ms/packet_drop_rate/call_drop_rate/"
          "rrc_setup_success_rate/throughput_mbps (KPIs), alarm_count/critical_alarm_count/"
          "event_count, capacity_erlangs/region/site_type")
    print(f"wrote {len(qoe_df)} rows -> {qoe_path}")
    print("  columns: site_id, latency_ms/jitter_ms/packet_drop_rate/call_drop_rate/"
          "rrc_setup_success_rate/throughput_mbps (KPIs), segment, nps_score, csat_score")
    print(f"wrote {len(site_meta_df)} rows -> {meta_path}")
    print("  columns: site_id, capacity_erlangs, high_value_count, subscriber_count, "
          "total_arpu, is_bad_site")
    print("\nEdit these CSVs by hand (e.g. push latency_ms/call_drop_rate higher for a site/hour) "
          "to see how that flows into the QoE score and triage rank, then run:")
    print("    python scripts/demo_from_csv.py")


if __name__ == "__main__":
    main()

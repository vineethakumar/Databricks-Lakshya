"""Same pipeline as scripts/demo_from_csv.py, but fetches its input with
actual SQL queries against a local SQLite database built from
data/mock/*.csv (scripts/mock_db.py), instead of a script reading the CSVs
directly with pandas — the closest a no-DB demo gets to the real query
path in src/data_loader.py (SELECT * FROM vw_site_hourly_features / ... /
db/02_views.sql), without needing an actual Oracle/Databricks instance.

Usage:
    python scripts/demo_from_sql.py
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.mock_data import (
    HORIZON_HOURS,
    LOOKBACK_HOURS,
    customer_impact_score,
    recommended_action,
    technical_severity_score,
)
from scripts.mock_db import DATA_DIR, build_db, fetch_df
from src.features import build_latest_windows, build_windowed_dataset
from src.models.call_event_lstm import CallEventLSTM
from src.models.qoe_regression import QoERegressor, compute_composite_qoe_label


def load_sql_inputs() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    conn = build_db(DATA_DIR)
    try:
        raw_df = fetch_df(conn, "SELECT * FROM vw_site_hourly_features ORDER BY site_id, hour_ts")
        raw_df["hour_ts"] = pd.to_datetime(raw_df["hour_ts"])
        qoe_df = fetch_df(conn, "SELECT * FROM vw_qoe_training_data")
        site_meta_df = fetch_df(conn, "SELECT * FROM vw_site_subscriber_value")
    finally:
        conn.close()
    return raw_df, qoe_df, site_meta_df


def main() -> None:
    print("=" * 78)
    print(f"STEP 1/4: fetching mock data via SQL (SQLite over {DATA_DIR})")
    print("=" * 78)
    raw_df, qoe_df, site_meta_df = load_sql_inputs()
    site_meta = {r.site_id: r._asdict() for r in site_meta_df.itertuples(index=False)}
    print(f"  {len(raw_df)} site-hours across {len(site_meta)} sites (SELECT * FROM vw_site_hourly_features)")
    print(f"  {len(qoe_df)} KPI->survey training rows (SELECT * FROM vw_qoe_training_data)")

    print("\n" + "=" * 78)
    print("STEP 2/4: training the LSTM (src/models/call_event_lstm.py) on SQL-fetched data")
    print("=" * 78)
    dataset = build_windowed_dataset(raw_df, lookback_hours=LOOKBACK_HOURS, horizon_hours=HORIZON_HOURS)
    print(f"  {dataset.X.shape[0]} training windows")
    lstm = CallEventLSTM.train(dataset.X, dataset.y, dataset.scaler, lookback_hours=LOOKBACK_HOURS, epochs=15)

    print("\n" + "=" * 78)
    print("STEP 3/4: training the QoE regressor (src/models/qoe_regression.py) on SQL-fetched data")
    print("=" * 78)
    qoe_model = QoERegressor.train(qoe_df)
    preds = qoe_model.predict(qoe_df)
    actual = compute_composite_qoe_label(qoe_df)
    print(f"  train MAE: {np.mean(np.abs(preds - actual)):.2f} (0-100 scale)")

    print("\n" + "=" * 78)
    print("STEP 4/4: inference + triage ranking (Python mirror of PKG_TRIAGE)")
    print("=" * 78)
    latest = build_latest_windows(raw_df, LOOKBACK_HOURS, lstm.scaler)
    call_preds = lstm.predict(latest.X)

    results = []
    for i, site_name in enumerate(latest.site_ids):
        call_volume, drop_rate, failure_prob = call_preds[i]
        meta = site_meta[site_name]

        latest_hour = raw_df[raw_df["site_id"] == site_name].sort_values("hour_ts").iloc[-1]
        segment_rows = pd.DataFrame([{
            "latency_ms": latest_hour["latency_ms"], "jitter_ms": latest_hour["jitter_ms"],
            "packet_drop_rate": latest_hour["packet_drop_rate"], "call_drop_rate": latest_hour["call_drop_rate"],
            "rrc_setup_success_rate": latest_hour["rrc_setup_success_rate"],
            "throughput_mbps": latest_hour["throughput_mbps"], "segment": seg,
        } for seg in ("HIGH_VALUE", "MEDIUM_VALUE", "LOW_VALUE")])
        qoe_score = float(np.mean(qoe_model.predict(segment_rows)))

        tech_score = technical_severity_score(drop_rate, failure_prob, critical_alarm_count=1 if meta["is_bad_site"] else 0)
        impact_score = customer_impact_score(qoe_score, meta["high_value_count"], meta["subscriber_count"], meta["total_arpu"])
        composite = round(impact_score * 0.6 + tech_score * 0.4, 3)

        results.append({
            "site_id": site_name,
            "predicted_call_volume": round(max(0.0, float(call_volume)), 1),
            "predicted_drop_rate": round(float(drop_rate), 4),
            "predicted_failure_prob": round(float(failure_prob), 4),
            "qoe_score": round(qoe_score, 1),
            "technical_severity_score": tech_score,
            "customer_impact_score": impact_score,
            "composite_priority_score": composite,
            "recommended_action": recommended_action(composite),
        })

    triage_df = pd.DataFrame(results).sort_values("composite_priority_score", ascending=False).reset_index(drop=True)
    triage_df.insert(0, "priority_rank", triage_df.index + 1)

    out_path = DATA_DIR / "triage_queue_output.csv"
    triage_df.to_csv(out_path, index=False)

    print("\nTriage queue (highest priority first):\n")
    print(triage_df.to_string(index=False))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()

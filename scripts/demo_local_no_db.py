"""Runs the real modeling code end to end WITHOUT Oracle: generates a small
synthetic dataset in memory (same shape/story as db/05_seed_data.sql — a
3-day incident on one site), trains the actual LSTM (src/models/
call_event_lstm.py) and QoE regressor (src/models/qoe_regression.py) on it,
runs inference, and re-ranks sites using a pure-Python mirror of the
PL/SQL triage math in db/03_packages.sql (PKG_TRIAGE).

This exists only because Docker/Oracle isn't available locally. It proves
the model code and business logic are correct, but it does NOT test the
actual PL/SQL (db/03_packages.sql runs only inside Oracle) or the Oracle
read/write path in src/db.py, src/data_loader.py, src/predict_and_score.py
— those need a real Oracle instance (see README.md's docker-compose path).

To inspect the generated mock data yourself (as CSV) instead of only
in-memory, use scripts/generate_mock_csv.py + scripts/demo_from_csv.py.

Usage:
    python scripts/demo_local_no_db.py
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
    generate_all,
    recommended_action,
    technical_severity_score,
)
from src.features import build_latest_windows, build_windowed_dataset
from src.models.call_event_lstm import CallEventLSTM
from src.models.qoe_regression import QoERegressor, compute_composite_qoe_label


def main() -> None:
    print("=" * 78)
    print("STEP 1/4: generating synthetic per-site hourly data (in memory, no DB)")
    print("=" * 78)
    raw_df, qoe_df, site_meta_df = generate_all()
    site_meta = {r.site_id: r._asdict() for r in site_meta_df.itertuples(index=False)}
    print(f"  {len(raw_df)} site-hours across {len(site_meta)} sites "
          f"(incident simulated on SITE-C-INDUSTRIAL)")
    print(f"  {len(qoe_df)} KPI->survey training rows")

    print("\n" + "=" * 78)
    print("STEP 2/4: training the LSTM (src/models/call_event_lstm.py) — real code, synthetic data")
    print("=" * 78)
    dataset = build_windowed_dataset(raw_df, lookback_hours=LOOKBACK_HOURS, horizon_hours=HORIZON_HOURS)
    print(f"  {dataset.X.shape[0]} training windows")
    lstm = CallEventLSTM.train(dataset.X, dataset.y, dataset.scaler, lookback_hours=LOOKBACK_HOURS, epochs=15)

    print("\n" + "=" * 78)
    print("STEP 3/4: training the QoE regressor (src/models/qoe_regression.py) — real code, synthetic data")
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

        # Latest KPI snapshot for this site, one row per segment mix, to
        # score QoE the same way src/predict_and_score.py does (subscriber-
        # count-weighted average across segments).
        latest_hour = raw_df[raw_df["site_id"] == site_name].sort_values("hour_ts").iloc[-1]
        segment_rows = pd.DataFrame([{
            "latency_ms": latest_hour["latency_ms"], "jitter_ms": latest_hour["jitter_ms"],
            "packet_drop_rate": latest_hour["packet_drop_rate"], "call_drop_rate": latest_hour["call_drop_rate"],
            "rrc_setup_success_rate": latest_hour["rrc_setup_success_rate"],
            "throughput_mbps": latest_hour["throughput_mbps"], "segment": seg,
        } for seg in ("HIGH_VALUE", "MEDIUM_VALUE", "LOW_VALUE")])
        qoe_score = float(np.mean(qoe_model.predict(segment_rows)))  # equal segment weighting for this demo

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

    print("\nTriage queue (highest priority first):\n")
    print(triage_df.to_string(index=False))


if __name__ == "__main__":
    main()

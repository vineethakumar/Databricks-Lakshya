"""Batch inference: runs both trained models on the latest data, writes
their output back into CALL_EVENT_PREDICTION and QOE_SCORE (as Delta
table appends via db.executemany), then calls etl.build_triage_queue so
the ranked worklist is ready in the same run.

Was Oracle-backed (raw INSERT SQL + PKG_TRIAGE.build_triage_queue via
callproc); now Delta-backed. Control flow and function names are
unchanged from the Oracle version — only the write mechanics (step 8 of
the conversion) and the triage-rebuild call (now a direct Python call
into src/etl.py instead of a stored-procedure call, step 5/6) changed.

Usage:
    python -m src.predict_and_score
"""
import pandas as pd

from . import config, db, etl
from .data_loader import load_site_hourly_features
from .features import build_latest_windows
from .models.call_event_lstm import CallEventLSTM
from .models.qoe_regression import QoERegressor


def run_call_event_predictions() -> pd.Timestamp:
    print("Running call-event LSTM inference ...")
    lstm = CallEventLSTM.load(config.MODEL_DIR / "call_event_lstm")
    raw_df = load_site_hourly_features()

    windows = build_latest_windows(raw_df, lstm.lookback_hours, lstm.scaler)
    preds = lstm.predict(windows.X)

    prediction_ts = pd.Series(windows.last_observed_ts).max() + pd.Timedelta(hours=config.LSTM_HORIZON_HOURS)

    rows = []
    for i, site_id in enumerate(windows.site_ids):
        call_volume, drop_rate, failure_prob = preds[i]
        target_ts = pd.Timestamp(windows.last_observed_ts[i]) + pd.Timedelta(hours=config.LSTM_HORIZON_HOURS)
        rows.append({
            "site_id": int(site_id),
            "prediction_ts": target_ts.to_pydatetime(),
            "horizon_hours": config.LSTM_HORIZON_HOURS,
            "predicted_call_volume": float(max(0, call_volume)),
            "predicted_drop_rate": float(min(max(drop_rate, 0), 1)),
            "predicted_failure_prob": float(min(max(failure_prob, 0), 1)),
            "risk_level": config.risk_level(float(failure_prob)),
            "model_version": config.LSTM_MODEL_VERSION,
        })

    # Delete-then-insert so re-running this against the same target hour
    # (e.g. re-running the demo pipeline) replaces rather than duplicates —
    # mirrors PKG_TRIAGE.build_triage_queue's own DELETE-then-INSERT pattern.
    db.execute(
        f"DELETE FROM {db.qualify('call_event_prediction')} "
        "WHERE prediction_ts = :prediction_ts AND model_version = :model_version",
        {"prediction_ts": prediction_ts.to_pydatetime(), "model_version": config.LSTM_MODEL_VERSION},
    )
    db.executemany("call_event_prediction", rows)
    print(f"  wrote {len(rows)} call_event_prediction rows")
    return prediction_ts


def run_qoe_scoring(score_ts: pd.Timestamp) -> None:
    print("Running QoE regression scoring ...")
    regressor = QoERegressor.load(config.MODEL_DIR / "qoe_regression")

    latest_kpi = db.fetch_df(f"""
        SELECT k.site_id, k.latency_ms, k.jitter_ms, k.packet_drop_rate,
               k.call_drop_rate, k.rrc_setup_success_rate, k.throughput_mbps
        FROM {db.qualify('network_kpi')} k
        WHERE k.kpi_ts = (SELECT MAX(k2.kpi_ts) FROM {db.qualify('network_kpi')} k2 WHERE k2.site_id = k.site_id)
    """)
    latest_kpi.columns = [c.lower() for c in latest_kpi.columns]

    segment_mix = db.fetch_df(f"""
        SELECT home_site_id AS site_id, segment, COUNT(*) AS subscriber_count
        FROM {db.qualify('subscriber')}
        GROUP BY home_site_id, segment
    """)
    segment_mix.columns = [c.lower() for c in segment_mix.columns]

    merged = segment_mix.merge(latest_kpi, on="site_id", how="inner")
    merged["predicted_qoe_score"] = regressor.predict(merged)

    site_scores = (
        merged.groupby("site_id")
        .apply(lambda g: (g["predicted_qoe_score"] * g["subscriber_count"]).sum() / g["subscriber_count"].sum())
        .reset_index(name="predicted_qoe_score")
    )

    rows = [{
        "site_id": int(r.site_id),
        "score_ts": score_ts.to_pydatetime(),
        "predicted_qoe_score": float(r.predicted_qoe_score),
        "qoe_band": config.qoe_band(float(r.predicted_qoe_score)),
        "model_version": config.QOE_MODEL_VERSION,
    } for r in site_scores.itertuples()]

    db.execute(
        f"DELETE FROM {db.qualify('qoe_score')} WHERE score_ts = :score_ts AND model_version = :model_version",
        {"score_ts": score_ts.to_pydatetime(), "model_version": config.QOE_MODEL_VERSION},
    )
    db.executemany("qoe_score", rows)
    print(f"  wrote {len(rows)} qoe_score rows")


def rebuild_triage_queue(prediction_ts: pd.Timestamp) -> None:
    print("Rebuilding triage queue (src.etl.build_triage_queue) ...")
    etl.build_triage_queue(prediction_ts.to_pydatetime())
    print("  done")


def main() -> None:
    prediction_ts = run_call_event_predictions()
    run_qoe_scoring(prediction_ts)
    rebuild_triage_queue(prediction_ts)

    top = db.fetch_df(f"""
        SELECT site_id, priority_rank, composite_priority_score, technical_severity_score,
               customer_impact_score, high_value_subscribers_affected, recommended_action
        FROM {db.qualify('triage_queue')}
        WHERE prediction_ts = :prediction_ts
        ORDER BY priority_rank
        LIMIT 10
    """, {"prediction_ts": prediction_ts.to_pydatetime()})
    print("\nTop of triage queue:")
    print(top.to_string(index=False))


if __name__ == "__main__":
    main()

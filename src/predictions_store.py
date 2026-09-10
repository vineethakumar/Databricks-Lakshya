"""Local SQLite store for predictions served by backend/app.py. Every
call to /api/predict/qoe or /api/predict/forecast is recorded here so
past predictions can be inspected without re-running the models."""
import sqlite3
from datetime import datetime, timezone

from . import config


def _connect() -> sqlite3.Connection:
    return sqlite3.connect(config.SQLITE_DB_PATH)


def init_db() -> None:
    conn = _connect()
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS qoe_predictions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                latency_ms REAL, jitter_ms REAL, packet_drop_rate REAL,
                call_drop_rate REAL, rrc_setup_success_rate REAL, throughput_mbps REAL,
                segment TEXT, score REAL, band TEXT
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS forecast_predictions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                site_id TEXT,
                predicted_call_volume REAL, predicted_drop_rate REAL,
                predicted_failure_prob REAL, risk_level TEXT
            )
        """)
        conn.commit()
    finally:
        conn.close()


def save_qoe_prediction(request: dict, result: dict) -> None:
    conn = _connect()
    try:
        conn.execute(
            """INSERT INTO qoe_predictions
               (created_at, latency_ms, jitter_ms, packet_drop_rate, call_drop_rate,
                rrc_setup_success_rate, throughput_mbps, segment, score, band)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                datetime.now(timezone.utc).isoformat(),
                request["latency_ms"], request["jitter_ms"], request["packet_drop_rate"],
                request["call_drop_rate"], request["rrc_setup_success_rate"], request["throughput_mbps"],
                request["segment"], result["score"], result["band"],
            ),
        )
        conn.commit()
    finally:
        conn.close()


def save_forecast_prediction(site_id: str, result: dict) -> None:
    conn = _connect()
    try:
        conn.execute(
            """INSERT INTO forecast_predictions
               (created_at, site_id, predicted_call_volume, predicted_drop_rate,
                predicted_failure_prob, risk_level)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                datetime.now(timezone.utc).isoformat(), site_id,
                result["predicted_call_volume"], result["predicted_drop_rate"],
                result["predicted_failure_prob"], result["risk_level"],
            ),
        )
        conn.commit()
    finally:
        conn.close()

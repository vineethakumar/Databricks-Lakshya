"""Central configuration, loaded from environment variables (.env)."""
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# --- Oracle connection (scripts/oracle_db.py) — kept for backward compatibility ---
DB_USER = os.getenv("DB_USER", "telecom_qoe")
DB_PASSWORD = os.getenv("DB_PASSWORD", "AppPassword123")
DB_DSN = os.getenv("DB_DSN", "localhost:1521/FREEPDB1")

# --- Databricks connection (src/db.py) ---
DATABRICKS_SERVER_HOSTNAME = os.getenv("DATABRICKS_SERVER_HOSTNAME")
DATABRICKS_HTTP_PATH = os.getenv("DATABRICKS_HTTP_PATH")
DATABRICKS_TOKEN = os.getenv("DATABRICKS_TOKEN")
DATABRICKS_CATALOG = os.getenv("DATABRICKS_CATALOG", "telecom_qoe_catalog")
DATABRICKS_SCHEMA = os.getenv("DATABRICKS_SCHEMA", "telecom_qoe")

# --- SQLite output store for predictions served by backend/app.py ---
SQLITE_DB_PATH = PROJECT_ROOT / os.getenv("SQLITE_DB_PATH", "predictions.db")

# --- Call-event LSTM ---
LSTM_LOOKBACK_HOURS = int(os.getenv("LSTM_LOOKBACK_HOURS", "24"))
LSTM_HORIZON_HOURS = int(os.getenv("LSTM_HORIZON_HOURS", "6"))
LSTM_MODEL_VERSION = "LSTM_V1"

# --- QoE regression ---
QOE_MODEL_VERSION = "REG_V1"

# Risk / band thresholds shared between training, inference, and PL/SQL
# rule-based scoring (db/03_packages.sql: pkg_qoe_scoring.qoe_band) so
# Python and PL/SQL bands stay consistent.
QOE_BANDS = [
    (85, "EXCELLENT"),
    (70, "GOOD"),
    (50, "FAIR"),
    (30, "POOR"),
    (0, "CRITICAL"),
]

RISK_LEVEL_THRESHOLDS = [
    (0.20, "CRITICAL"),
    (0.10, "HIGH"),
    (0.04, "MODERATE"),
    (0.0, "LOW"),
]


def qoe_band(score: float) -> str:
    for threshold, band in QOE_BANDS:
        if score >= threshold:
            return band
    return "CRITICAL"


def risk_level(failure_prob: float) -> str:
    for threshold, level in RISK_LEVEL_THRESHOLDS:
        if failure_prob >= threshold:
            return level
    return "LOW"

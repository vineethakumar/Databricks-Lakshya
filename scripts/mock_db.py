"""Loads scripts/mock_data.py's CSVs into a local SQLite database and
exposes the same feature views the real Databricks pipeline queries
(db/02_views.sql: VW_SITE_HOURLY_FEATURES / VW_QOE_TRAINING_DATA /
VW_SITE_SUBSCRIBER_VALUE), so scripts/demo_from_sql.py fetches its input
with actual SQL SELECTs instead of a script generating or reading the data
directly."""
import sqlite3
from pathlib import Path

import pandas as pd

from scripts.mock_data import load_or_generate

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "mock"


def build_db(data_dir: Path = DATA_DIR) -> sqlite3.Connection:
    """Loads the mock CSVs under data_dir (generating them there once if
    missing) into an in-memory SQLite database and creates views over them
    with the same names as db/02_views.sql, so callers query this exactly
    like the Databricks-backed path in src/data_loader.py does."""
    raw_df, qoe_df, site_meta_df = load_or_generate(data_dir)

    conn = sqlite3.connect(":memory:")
    raw_df.to_sql("site_hourly_features", conn, index=False)
    qoe_df.to_sql("qoe_training_data", conn, index=False)
    site_meta_df.to_sql("site_meta", conn, index=False)

    conn.execute("CREATE VIEW vw_site_hourly_features AS SELECT * FROM site_hourly_features")
    conn.execute("CREATE VIEW vw_qoe_training_data AS SELECT * FROM qoe_training_data")
    conn.execute("CREATE VIEW vw_site_subscriber_value AS SELECT * FROM site_meta")
    return conn


def fetch_df(conn: sqlite3.Connection, sql: str) -> pd.DataFrame:
    """Run a SELECT against the db built by build_db() and return a
    DataFrame — the same fetch_df(sql) shape as src/db.py."""
    return pd.read_sql_query(sql, conn)

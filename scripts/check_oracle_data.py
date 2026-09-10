"""Quick standalone check: what actually exists in the configured Oracle
schema right now? Lists every table/view you own, then specifically
reports on the two views backend/app.py requires (vw_site_hourly_features,
vw_qoe_training_data) -- row counts + a sample row if they exist.

Usage:
    python -m scripts.check_oracle_data
"""
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.oracle_db import build_db, fetch_df
from src import config

REQUIRED_VIEWS = ["vw_site_hourly_features", "vw_qoe_training_data"]


def main() -> None:
    print(f"Connecting to {config.DB_DSN} as {config.DB_USER} ...")
    conn = build_db()
    try:
        print("\nAll tables in this schema:")
        tables = fetch_df(conn, "SELECT table_name FROM user_tables ORDER BY table_name")
        print(tables.to_string(index=False) if len(tables) else "  (none)")

        print("\nAll views in this schema:")
        views = fetch_df(conn, "SELECT view_name FROM user_views ORDER BY view_name")
        print(views.to_string(index=False) if len(views) else "  (none)")

        print("\nRequired views for backend/app.py:")
        for view in REQUIRED_VIEWS:
            exists = view.upper() in views["view_name"].values if len(views) else False
            if not exists:
                print(f"  {view:<26} MISSING")
                continue
            df = fetch_df(conn, f"SELECT * FROM {view}")
            print(f"  {view:<26} {len(df)} rows, columns: {list(df.columns)}")
            if len(df):
                print(df.head(3).to_string(index=False))
            print()
    finally:
        conn.close()


if __name__ == "__main__":
    main()
